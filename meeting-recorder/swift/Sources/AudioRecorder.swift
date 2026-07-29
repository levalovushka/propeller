import AVFoundation
import Foundation
import os
import PropellerMetrics
import PropellerPure

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
    /// is true. Provides Apple's built-in echo cancellation so speaker-on
    /// meetings don't bleed remote audio back into the mic stem.
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
    /// Seconds of microphone audio already on disk when the system stem opened —
    /// i.e. where that stem starts on this recording's timeline (`StemTimeline`).
    /// Nil until the first system buffer lands, and forever on mic-only.
    private(set) var systemStemOffset: TimeInterval?
    /// The same number, kept past `stop()` so the caller can persist it with the
    /// recording: a crash-recovered re-mix must not have to guess it again.
    private(set) var lastStopSystemStemOffset: TimeInterval?
    /// Whether the finished recording's system stem came from the meeting app or
    /// from the whole machine.
    private(set) var lastStopWasAppScoped: Bool?
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
        systemStemOffset = nil
        debugLog("[AudioRecorder] start() called — captureSystemAudio=\(Preferences.shared.captureSystemAudio)")

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

        // Plain AVAudioRecorder only. Apple's voice processing (VPIO) used to be
        // offered here as "подавлять эхо динамика", and it reconfigures the shared
        // input device rather than just our own capture: one tester became almost
        // inaudible to everyone else on the call. A recorder must never degrade
        // the meeting it is recording, so the option and its engine are gone.
        avRecorder = try AVAudioRecorder(url: micURL, settings: settings)
        avRecorder?.isMeteringEnabled = true
        guard let recorder = avRecorder, recorder.record() else {
            throw RecorderError.failedToStart
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
                sck.onFirstSample = { [weak self] sampleAge in
                    // Timestamp here, on the capture queue: the stem started when
                    // this fired, not when the main actor got round to us.
                    let firedAt = Date()
                    Task { @MainActor in
                        guard let self, let recorder = self.avRecorder else { return }
                        let hop = Date().timeIntervalSince(firedAt)
                        // Две поправки, обе вычитаются: прыжок на этот актор и
                        // возраст первого сэмпла в момент доставки.
                        let offset = max(0, recorder.currentTime - hop - sampleAge)
                        // Overwrites on purpose: a scoped→display-wide fallback
                        // starts the stem file over, and then the stem begins
                        // later than it first did.
                        let previous = self.systemStemOffset
                        self.systemStemOffset = offset
                        if let previous {
                            NSLog("[AudioRecorder] system stem restarted — offset \(Int(previous * 1000)) → \(Int(offset * 1000)) ms")
                        } else {
                            NSLog("[AudioRecorder] system stem opens \(Int(offset * 1000)) ms into the mic timeline (first sample was \(Int(sampleAge * 1000)) ms old)")
                        }
                    }
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
        // Свежий снимок, а не отладенное состояние детектора: между входом в
        // звонок и его подтверждением проходит до двух опросов, а область
        // захвата выбирается один раз и на всю запись.
        let platformID = MeetingDetector.captureSnapshot().platformID
        do {
            try await sck.start(outputURL: sysURL, callPlatformID: platformID)
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
        recordedDuration = avRecorder?.currentTime ?? 0
        avRecorder?.stop()
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
        recordingID = nil
        filePath = nil
        startTime = nil

        // Stop capture then mix — awaited so the WAV is fully written before returning.
        let sysCapture = systemAudio
        systemAudio = nil
        systemAudioURL = nil
        let stemOffset = systemStemOffset ?? 0
        lastStopSystemStemOffset = systemStemOffset
        systemStemOffset = nil

        let micOnly = try await Task.detached(priority: .userInitiated) { () -> Bool in
            var stemUnusable = sysURL == nil
            var appScoped: Bool?
            if #available(macOS 14.0, *), let capture = sysCapture as? SystemAudioCapture {
                await capture.stop()
                let report = capture.report()
                NSLog("[AudioRecorder] SCK report: \(report.logLine)")
                let drift = await capture.timestampDrift()
                NSLog(String(
                    format: "[AudioRecorder] SCK timestamp drift: last %.1f ms, range %.1f…%.1f ms",
                    drift.last, drift.min, drift.max
                ))
                stemUnusable = !report.capturedUsableStem
                appScoped = report.appScoped
            } else if let sysURL {
                let size = (try? FileManager.default.attributesOfItem(atPath: sysURL.path)[.size] as? NSNumber)?.intValue ?? 0
                stemUnusable = size <= 4096
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            await Self.produceFinalMix(
                micURL: micURL, sysURL: sysURL, finalURL: finalURL,
                systemStemOffset: stemOffset
            )
            await MainActor.run { [appScoped] in self.lastStopWasAppScoped = appScoped }
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
            if let rec = self.avRecorder {
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
                if let rec = self.avRecorder {
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
    static func produceFinalMix(
        micURL: URL,
        sysURL: URL?,
        finalURL: URL,
        systemStemOffset: TimeInterval = 0
    ) async {
        let fm = FileManager.default
        // Есть стем — микшуем. Здесь стоял третий по счёту порог «слышимости»
        // (`hasAudibleContent`), и он отвечал на вопрос, которого не задавали:
        // тишину микшировать не вредно — `MixGain` на тихом стеме возвращает 1,
        // то есть складывает тишину с микрофоном и ничего не усиливает. Зато
        // порог мог выбросить настоящую, но тихую дальнюю сторону целиком.
        // Заодно ушло чтение всего стема ради одной строки в лог.
        let hasSys: Bool = {
            guard let u = sysURL else { return false }
            guard let attrs = try? fm.attributesOfItem(atPath: u.path),
                  let size = attrs[.size] as? NSNumber else { return false }
            return size.intValue > 4096
        }()

        if !hasSys {
            // Стема нет вовсе (mic-only) — копируем микрофон в финал.
            _ = try? fm.removeItem(at: finalURL)
            do { try fm.copyItem(at: micURL, to: finalURL) } catch {
                debugLog("[AudioRecorder] copy mic → final failed: \(error)")
            }
            return
        }

        // Mix using AVAudioEngine offline rendering.
        do {
            try await PipelineMetrics.interval(PipelineMetrics.pipeline, PipelineMetrics.mix) {
                try await Self.mix(
                    micURL: micURL, sysURL: sysURL!, finalURL: finalURL,
                    systemStemOffset: systemStemOffset
                )
            }
        } catch {
            debugLog("[AudioRecorder] offline mix failed, falling back to mic only: \(error)")
            _ = try? fm.removeItem(at: finalURL)
            try? fm.copyItem(at: micURL, to: finalURL)
        }
    }

    private static func mix(
        micURL: URL,
        sysURL: URL,
        finalURL: URL,
        systemStemOffset: TimeInterval
    ) async throws {
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

        // The system stem does not start when the microphone does — it opens
        // `systemStemOffset` seconds in, and summing both from index zero is what
        // put the far end into the recording twice, half a second apart
        // (`StemTimeline`, docs/ECHO_AND_MIX_EXPERIMENTS.md).
        let micN = Int(micMono.frameLength)
        let sysN = Int(sysMono.frameLength)
        let sysStart = StemTimeline.systemStartFrame(
            offsetSeconds: systemStemOffset, sampleRate: targetSR
        )
        let n = AVAudioFrameCount(
            StemTimeline.mixedFrameCount(
                micFrames: micN, systemFrames: sysN, systemStartFrame: sysStart
            )
        )
        debugLog("[AudioRecorder] mixing mic=\(micN) sys=\(sysN) frames, system stem placed at \(sysStart) frames (\(Int(systemStemOffset * 1000)) ms)")

        // Sum with soft clamp. System audio can arrive quieter than the mic,
        // so apply a bounded automatic gain before clamping.
        guard n > 0, let mixed = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: n) else {
            throw RecorderError.failedToMix
        }
        mixed.frameLength = n
        guard let mixPtr = mixed.floatChannelData?[0],
              let micPtr = micMono.floatChannelData?[0],
              let sysPtr = sysMono.floatChannelData?[0] else {
            throw RecorderError.failedToMix
        }
        for i in 0..<Int(n) {
            let m = i < micN ? micPtr[i] : 0
            let j = i - sysStart
            let s = (j >= 0 && j < sysN) ? sysPtr[j] * sysGain : 0
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
