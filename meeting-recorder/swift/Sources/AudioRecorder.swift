import AVFoundation
import Foundation
import os
import PropellerMetrics
import PropellerPure
import SpeakerMatchingCore

/// Unified logging — near-zero cost when unused, no unbounded file growth
/// (plan-optimization E6). Kept as a free function so existing call sites stay.
func debugLog(_ msg: String) {
    Logger(subsystem: "app.propeller", category: "debug").debug("\(msg, privacy: .public)")
}

@MainActor
class AudioRecorder: ObservableObject {
    @Published var isRecording = false

    // Mic recording (legacy AVAudioRecorder path).
    private var avRecorder: AVAudioRecorder?
    /// Voice-processed mic capture — used when Preferences.voiceProcessingEnabled
    /// is true. Provides Apple's built-in echo cancellation so speaker-on
    /// meetings don't bleed remote audio back into the mic stem.
    private var vpCapture: VoiceProcessedMicCapture?
    private(set) var startTime: Date?
    private(set) var recordingID: String?
    private(set) var filePath: URL?
    private(set) var duration: TimeInterval = 0

    // System-audio side channel via ScreenCaptureKit.
    // Process Tap was flaky (header-only stems + false "not captured" banners);
    // onboarding already asks for Screen Recording, so SCK is the single path.
    private var systemAudio: AnyObject?
    private var systemAudioURL: URL?
    /// Hard start failure only (permission / stream won't start). Not used for
    /// "quiet so far" — live System levels are the truth during recording.
    @Published var systemAudioWarning: String?
    /// Set in `stop()` from the actual `.sys.wav` stem (empty / missing).
    private(set) var lastStopWasMicOnly = false
    /// Non-nil if the mic writer isn't actually producing frames shortly after
    /// start (e.g. input device disappeared). Unlike system audio, the mic is
    /// the essential source — this is surfaced immediately, not tagged post-hoc.
    @Published var micCaptureWarning: String?

    /// Rolling history of mic audio levels (0–1) for waveform display.
    @Published var micLevelHistory: [Float] = []
    /// Rolling history of system audio levels (0–1) for waveform display.
    @Published var systemLevelHistory: [Float] = []
    private var meterTimer: Timer?
    private static let historySize = 50
    /// When false, metering is paused (window closed / accessory) — recording continues (E5).
    private var meteringDesired = false

    var elapsed: TimeInterval {
        guard let start = startTime, isRecording else { return 0 }
        return Date().timeIntervalSince(start)
    }

    func start() throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        systemAudioWarning = nil
        micCaptureWarning = nil
        lastStopWasMicOnly = false
        debugLog("[AudioRecorder] start() called — captureSystemAudio=\(Preferences.shared.captureSystemAudio) voiceProcessing=\(Preferences.shared.voiceProcessingEnabled)")

        let recordingsDir = URL(fileURLWithPath: Preferences.shared.recordingsPath)
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let id = Self.makeID()
        let micURL = recordingsDir.appendingPathComponent("\(id).mic.wav")
        let finalURL = recordingsDir.appendingPathComponent("\(id).wav")
        let sysURL = recordingsDir.appendingPathComponent("\(id).sys.wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        if Preferences.shared.voiceProcessingEnabled {
            // Voice-processed path: AVAudioEngine + AEC + noise suppression.
            // Falls back to AVAudioRecorder on failure (e.g. another app already
            // owns the input device with an incompatible voice-processing config).
            do {
                let capture = VoiceProcessedMicCapture()
                try capture.start(outputURL: micURL)
                vpCapture = capture
                debugLog("[AudioRecorder] Voice-processed mic capture started")
            } catch {
                debugLog("[AudioRecorder] Voice-processing capture failed (\(error)) — using AVAudioRecorder")
                avRecorder = try AVAudioRecorder(url: micURL, settings: settings)
                avRecorder?.isMeteringEnabled = true
                guard let recorder = avRecorder, recorder.record() else {
                    throw RecorderError.failedToStart
                }
            }
        } else {
            avRecorder = try AVAudioRecorder(url: micURL, settings: settings)
            avRecorder?.isMeteringEnabled = true
            guard let recorder = avRecorder, recorder.record() else {
                throw RecorderError.failedToStart
            }
        }

        recordingID = id
        filePath = finalURL
        startTime = Date()
        isRecording = true
        armMicIntegrityWatchdog()

        // System audio: ScreenCaptureKit only. Live levels = health; no speculative banners.
        if Preferences.shared.captureSystemAudio {
            systemAudioURL = sysURL
            if #available(macOS 14.0, *) {
                let sck = SystemAudioCapture()
                sck.onCaptureIssueDetected = { message in
                    // Soft mid-session issues stay in the log — UI banner is reserved
                    // for start() failure so it can't disagree with a live System meter.
                    NSLog("[AudioRecorder] System audio note: \(message)")
                }
                systemAudio = sck
            }
        }

        // Metering starts only when the UI asks for it (window open) — E5.
        if meteringDesired {
            startMetering()
        }

        if Preferences.shared.captureSystemAudio {
            Task.detached { [weak self] in
                await self?.startSystemAudioCapture(sysURL: sysURL)
            }
        }
    }

    private func startSystemAudioCapture(sysURL: URL) async {
        guard #available(macOS 14.0, *),
              let sck = await MainActor.run(body: { self.systemAudio as? SystemAudioCapture }) else { return }
        do {
            try await sck.start(outputURL: sysURL)
            NSLog("[AudioRecorder] SCK system audio started")
            await MainActor.run { self.systemAudioWarning = nil }
        } catch {
            await MainActor.run {
                self.systemAudioWarning = error.localizedDescription
                NSLog("[AudioRecorder] System audio capture FAILED to start: \(error)")
            }
        }
    }

    /// Enable/pause live level metering. Recording itself is unaffected (E5).
    func setMeteringDesired(_ desired: Bool) {
        meteringDesired = desired
        guard isRecording else { return }
        if desired {
            if meterTimer == nil { startMetering() }
        } else {
            stopMetering()
        }
    }

    func stop() async throws -> (id: String, url: URL, duration: TimeInterval) {
        stopMetering()
        let recordedDuration: TimeInterval
        if let vp = vpCapture {
            recordedDuration = vp.recordedDuration
            vp.stop()
        } else {
            recordedDuration = avRecorder?.currentTime ?? 0
            avRecorder?.stop()
        }
        let dur = recordedDuration > 0
            ? recordedDuration
            : Date().timeIntervalSince(startTime ?? Date())
        let id = recordingID ?? ""
        let finalURL = filePath ?? URL(fileURLWithPath: "")
        let sysURL = systemAudioURL
        let recordingsDir = finalURL.deletingLastPathComponent()
        let micURL = recordingsDir.appendingPathComponent("\(id).mic.wav")

        duration = dur
        isRecording = false
        avRecorder = nil
        vpCapture = nil
        recordingID = nil
        filePath = nil
        startTime = nil

        // Stop capture then mix — awaited so the WAV is fully written before returning.
        let sysCapture = systemAudio
        systemAudio = nil
        systemAudioURL = nil

        let micOnly = try await Task.detached(priority: .userInitiated) { () -> Bool in
            var stemUnusable = sysURL == nil
            if #available(macOS 14.0, *), let capture = sysCapture as? SystemAudioCapture {
                await capture.stop()
                let report = capture.report()
                NSLog("[AudioRecorder] SCK report: \(report.logLine)")
                stemUnusable = !report.capturedUsableStem
            } else if let sysURL {
                let size = (try? FileManager.default.attributesOfItem(atPath: sysURL.path)[.size] as? NSNumber)?.intValue ?? 0
                stemUnusable = size <= 4096
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            await Self.produceFinalMix(micURL: micURL, sysURL: sysURL, finalURL: finalURL)
            return stemUnusable
        }.value

        lastStopWasMicOnly = Preferences.shared.captureSystemAudio && micOnly
        // Clear any start-failure banner once recording ends — detail uses mic-only tag.
        systemAudioWarning = nil

        return (id, finalURL, dur)
    }

    /// Confirms the mic writer is actually producing frames shortly after
    /// start, rather than silently discovering at stop time that nothing was
    /// captured (e.g. the input device disappeared right after `record()`
    /// returned true). Checks recorded-duration progress, not just
    /// `isRecording`, since a stalled writer can stay "running" with no data.
    private func armMicIntegrityWatchdog() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.isRecording else { return }
            let progressed: TimeInterval
            if let vp = self.vpCapture {
                progressed = vp.recordedDuration
            } else if let rec = self.avRecorder {
                progressed = rec.currentTime
            } else {
                progressed = 0
            }
            if progressed < 1.5 {
                let message = "Микрофон не пишет — в первые секунды аудио не записалось. Проверьте устройство ввода."
                debugLog("[AudioRecorder] WARNING: \(message) (progressed=\(progressed)s)")
                self.micCaptureWarning = message
            }
        }
    }

    private static func makeID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    // MARK: - Audio Level Metering

    private func startMetering() {
        micLevelHistory = Array(repeating: 0, count: Self.historySize)
        systemLevelHistory = Array(repeating: 0, count: Self.historySize)

        let onLevel: (Float) -> Void = { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, self.meteringDesired else { return }
                self.systemLevelHistory.append(level)
                if self.systemLevelHistory.count > Self.historySize {
                    self.systemLevelHistory.removeFirst(self.systemLevelHistory.count - Self.historySize)
                }
            }
        }
        if #available(macOS 14.0, *), let capture = systemAudio as? SystemAudioCapture {
            capture.levelCallback = onLevel
        }

        // ~10 Hz (was 12.5) — enough for a smooth waveform, less MainActor churn (E5/S6).
        let interval: TimeInterval = 0.1
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, self.meteringDesired else { return }
                let normalized: Float
                if let vp = self.vpCapture {
                    normalized = vp.currentLevel
                } else if let rec = self.avRecorder {
                    rec.updateMeters()
                    let db = rec.averagePower(forChannel: 0)
                    normalized = max(0, min(1, (db + 50) / 50))
                } else {
                    return
                }
                self.micLevelHistory.append(normalized)
                if self.micLevelHistory.count > Self.historySize {
                    self.micLevelHistory.removeFirst(self.micLevelHistory.count - Self.historySize)
                }
                // If no system audio capture, still push zeros so the waveform stays aligned
                if self.systemAudio == nil || self.systemAudioWarning != nil {
                    self.systemLevelHistory.append(0)
                    if self.systemLevelHistory.count > Self.historySize {
                        self.systemLevelHistory.removeFirst(self.systemLevelHistory.count - Self.historySize)
                    }
                }
            }
        }
        timer.tolerance = interval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        if #available(macOS 14.0, *), let capture = systemAudio as? SystemAudioCapture {
            capture.levelCallback = nil
        }
    }

    // MARK: - Offline mix of mic + system audio

    /// Produces the final 16kHz mono WAV at `finalURL` by summing mic + system audio.
    /// If the system-audio file is missing or empty, the mic recording is copied verbatim.
    /// Raw stems are retained next to the final file so speaker matching can
    /// infer whether a diarized voice came mostly from mic or system audio.
    /// Offline mix of mic (+ optional system) stems into the final 16 kHz mono WAV.
    /// Also used by crash-recovery when only `.mic.wav` survived (plan-optimization C3).
    static func produceFinalMix(micURL: URL, sysURL: URL?, finalURL: URL) async {
        let fm = FileManager.default
        let sysSummary: AudioEnergySummary? = {
            guard let u = sysURL else { return nil }
            guard let attrs = try? fm.attributesOfItem(atPath: u.path),
                  let size = attrs[.size] as? NSNumber else { return nil }
            guard size.intValue > 4096 else { return nil }
            return try? AudioEnergyAnalyzer.summarize(url: u)
        }()
        if let sysSummary {
            debugLog("[AudioRecorder] System stem energy: duration=\(String(format: "%.2f", sysSummary.duration))s rms=\(String(format: "%.6f", sysSummary.rms)) peak=\(String(format: "%.6f", sysSummary.peak)) active=\(String(format: "%.3f", sysSummary.activeRatio))")
        }
        let hasSys = sysSummary?.hasAudibleContent ?? false

        if !hasSys {
            // No system audio — copy mic.wav → final.wav and keep the stem.
            _ = try? fm.removeItem(at: finalURL)
            do { try fm.copyItem(at: micURL, to: finalURL) } catch {
                debugLog("[AudioRecorder] copy mic → final failed: \(error)")
            }
            return
        }

        // Mix using AVAudioEngine offline rendering.
        do {
            try await PipelineMetrics.interval(PipelineMetrics.pipeline, PipelineMetrics.mix) {
                try await Self.mix(micURL: micURL, sysURL: sysURL!, finalURL: finalURL)
            }
        } catch {
            debugLog("[AudioRecorder] offline mix failed, falling back to mic only: \(error)")
            _ = try? fm.removeItem(at: finalURL)
            try? fm.copyItem(at: micURL, to: finalURL)
        }
    }

    private static func mix(micURL: URL, sysURL: URL, finalURL: URL) async throws {
        let micFile = try AVAudioFile(forReading: micURL)
        let sysFile = try AVAudioFile(forReading: sysURL)

        // Final format: same as existing pipeline — 16kHz mono.
        let targetSR: Double = 16_000
        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSR,
            channels: 1,
            interleaved: false
        )!
        let writeSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: targetSR,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        _ = try? FileManager.default.removeItem(at: finalURL)
        let outFile = try AVAudioFile(forWriting: finalURL, settings: writeSettings)

        let micMono = try Self.readAndResample(file: micFile, to: outFormat)
        let sysMono = try Self.readAndResample(file: sysFile, to: outFormat)
        let sysGain = Self.systemMixGain(mic: micMono, system: sysMono)
        debugLog("[AudioRecorder] Mixing mic + system with systemGain=\(String(format: "%.2f", sysGain))")

        // Sum with soft clamp. System audio can arrive quieter than the mic,
        // so apply a bounded automatic gain before clamping.
        let n = max(micMono.frameLength, sysMono.frameLength)
        guard let mixed = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: n) else {
            throw RecorderError.failedToMix
        }
        mixed.frameLength = n
        guard let mixPtr = mixed.floatChannelData?[0],
              let micPtr = micMono.floatChannelData?[0],
              let sysPtr = sysMono.floatChannelData?[0] else {
            throw RecorderError.failedToMix
        }
        let micN = Int(micMono.frameLength)
        let sysN = Int(sysMono.frameLength)
        for i in 0..<Int(n) {
            let m = i < micN ? micPtr[i] : 0
            let s = i < sysN ? sysPtr[i] * sysGain : 0
            var v = m + s
            if v > 1.0 { v = 1.0 } else if v < -1.0 { v = -1.0 }
            mixPtr[i] = v
        }
        try outFile.write(from: mixed)
    }

    private static func systemMixGain(mic: AVAudioPCMBuffer, system: AVAudioPCMBuffer) -> Float {
        let micStats = bufferStats(mic)
        let systemStats = bufferStats(system)
        return MixGain.systemMixGain(
            micRMS: micStats.rms, micPeak: micStats.peak,
            systemRMS: systemStats.rms, systemPeak: systemStats.peak
        )
    }

    private static func bufferStats(_ buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float) {
        guard let data = buffer.floatChannelData else { return (0, 0) }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return (0, 0) }
        var sumSq: Float = 0
        var peak: Float = 0
        var count = 0
        for channel in 0..<channels {
            let p = data[channel]
            for frame in 0..<frames {
                let value = p[frame]
                sumSq += value * value
                peak = max(peak, abs(value))
                count += 1
            }
        }
        guard count > 0 else { return (0, 0) }
        return (sqrt(sumSq / Float(count)), peak)
    }

    private static func readAndResample(file: AVAudioFile, to outFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else {
            return AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 1)!
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount) else {
            throw RecorderError.failedToMix
        }
        try file.read(into: input)

        if inFormat.sampleRate == outFormat.sampleRate && inFormat.channelCount == 1 {
            return input
        }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw RecorderError.failedToMix
        }
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw RecorderError.failedToMix
        }
        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: output, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw convError ?? RecorderError.failedToMix
        }
        return output
    }

    enum RecorderError: LocalizedError {
        case alreadyRecording, failedToStart, failedToMix
        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "Уже идёт запись"
            case .failedToStart: return "Не удалось начать запись"
            case .failedToMix: return "Не удалось свести микрофон и системный звук"
            }
        }
    }
}

// MARK: - Voice-Processed Mic Capture

/// Microphone capture using AVAudioEngine with the voice-processing input
/// node enabled. Engages Apple's acoustic echo cancellation + noise
/// suppression — same engine FaceTime/Zoom use internally — so when the
/// user is on a call without headphones, the remote participants' voices
/// coming back through the mic are subtracted before reaching the file.
///
/// Writes a 16kHz mono int16 PCM WAV at the requested URL, matching the
/// format produced by the legacy `AVAudioRecorder` path so the rest of the
/// pipeline (mixer, diarizer, transcriber) doesn't have to know which
/// backend ran. Lock-protected internally because the tap callback fires
/// on the audio render thread.
final class VoiceProcessedMicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var _level: Float = 0
    private var _outputFrames: Int64 = 0
    private let outputSampleRate: Double = 16_000

    var currentLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return _level
    }

    /// Duration of audio committed to disk so far, in seconds. Computed
    /// from the output sample rate to stay accurate even if the input
    /// node negotiates a different rate (VPIO often selects 24kHz).
    var recordedDuration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(_outputFrames) / outputSampleRate
    }

    func start(outputURL: URL) throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)

        // Clamp the "other audio" ducking to its minimum so VPIO doesn't drop
        // the system output level just to make AEC easier — that made the
        // meeting itself inaudible to the user. AGC is left at its default
        // (enabled) because disabling it produces a near-silent mic capture
        // on macOS — the input pre-amp is part of how VPIO surfaces audio.
        if #available(macOS 14.0, *) {
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
        }

        let inputFormat = input.outputFormat(forBus: 0)
        debugLog("[VoiceProcessedMic] input format: sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount)")

        let writeSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let f = try AVAudioFile(forWriting: outputURL, settings: writeSettings)
        let conv = AVAudioConverter(from: inputFormat, to: f.processingFormat)

        lock.lock()
        self.file = f
        self.converter = conv
        self._outputFrames = 0
        self._level = 0
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        // Leave VPIO engaged and other-audio ducking can mute headphones
        // for the rest of the process lifetime — turn it off explicitly.
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        engine.stop()
        engine.reset()
        lock.lock()
        file = nil
        converter = nil
        lock.unlock()
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        let level = Self.normalizedLevel(buffer)
        let inFormat = buffer.format

        lock.lock()
        defer { lock.unlock() }

        _level = level
        guard let f = file, let conv = converter else { return }

        let outFormat = f.processingFormat
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return }

        var consumed = false
        var convError: NSError?
        let status = conv.convert(to: outBuf, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status != .error, outBuf.frameLength > 0 {
            do {
                try f.write(from: outBuf)
                _outputFrames += Int64(outBuf.frameLength)
            } catch {
                NSLog("[VoiceProcessedMic] file write error: \(error)")
            }
        }
    }

    /// RMS-based 0–1 level, calibrated against the same -50dB → 0 floor
    /// AVAudioRecorder uses, so the waveform display behaves identically.
    private static func normalizedLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return 0 }
        var sumSq: Float = 0
        var count = 0
        for c in 0..<channels {
            let p = data[c]
            for i in 0..<frames {
                let v = p[i]
                sumSq += v * v
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let rms = sqrt(sumSq / Float(count))
        let db = rms > 0 ? 20 * log10f(rms) : -120
        return max(0, min(1, (db + 50) / 50))
    }
}
