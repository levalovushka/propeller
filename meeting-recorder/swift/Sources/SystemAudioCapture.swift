import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Captures the system audio output (what would be heard through the speakers/headphones)
/// using ScreenCaptureKit's audio-only stream. Requires macOS 14+ and Screen Recording
/// permission. The stream is 48 kHz stereo, but the stem is written as **16 kHz mono
/// Int16** — the same shape as the mic stem and everything that consumes it.
/// Offline-mixing into the final recording is done by `AudioRecorder` on stop.
@available(macOS 14.0, *)
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Meeting apps we scope capture to by default, so we tap only the call's
    /// audio instead of the whole system mix (music, other calls, notifications).
    static let meetingAppBundleIDs = ["us.zoom.xos"]

    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    /// 48 kHz stereo Float32 → 16 kHz mono Int16, reused across callbacks so the
    /// resampler keeps its state between buffers. Nil until the first buffer
    /// establishes the input format, or after a failure downgrades us to native.
    private var stemConverter: AVAudioConverter?
    /// Set when conversion failed and we fell back to the stream's own format.
    /// Capture reliability outweighs stem size: a smaller file is worthless if
    /// the other side of the call is missing.
    private var stemConversionDisabled = false
    /// When true, sample callbacks must not recreate the WAV (would truncate — C10).
    private var didStopWriting = false
    private let sampleQueue = DispatchQueue(label: "com.simplyai.meeting-recorder.sck-audio")
    private(set) var outputURL: URL?
    private(set) var isRunning = false
    private var didSeeAnySamples = false
    private var pcmBufferCount = 0
    private var conversionFailureCount = 0
    private var framesWritten = 0
    private var audibleBufferCount = 0
    private var maxRMSLevel: Float = 0
    private var maxPeakLevel: Float = 0

    /// True while the active stream is scoped to specific meeting apps rather
    /// than the whole display.
    private(set) var isAppScoped = false
    /// Guards against a fallback restart loop — only try display-wide once.
    private var didFallBackToDisplayWide = false

    /// Called on the sample queue with the current RMS level (0.0–1.0) each time a buffer arrives.
    var levelCallback: ((Float) -> Void)?

    /// Called when the stream appears to be running but audio capture itself is unhealthy.
    var onCaptureIssueDetected: ((String) -> Void)?

    private var sampleWatchdog: Task<Void, Never>?

    struct CaptureReport {
        let callbackCount: Int
        let pcmBufferCount: Int
        let conversionFailureCount: Int
        let framesWritten: Int
        let audibleBufferCount: Int
        let maxRMSLevel: Float
        let maxPeakLevel: Float
        let outputFileSizeBytes: Int64?

        var capturedAudibleAudio: Bool {
            audibleBufferCount > 0 || maxPeakLevel > 0.0005
        }

        /// True when the stem has real PCM (not a header-only ~4 KB file).
        /// Silence still counts — remote speakers may simply not have talked.
        var capturedUsableStem: Bool {
            if let bytes = outputFileSizeBytes, bytes > 4096 { return true }
            return framesWritten > 8_000
        }

        var warningMessage: String? {
            if callbackCount == 0 {
                return "Поток системного звука запущен, но буферы не приходят. Разрешение «Запись экрана» могло устареть — выключите и включите его в Системных настройках, затем перезапустите приложение."
            }
            if pcmBufferCount == 0, conversionFailureCount > 0 {
                return "Буферы системного звука пришли, но не удалось их декодировать. Удалённая сторона не записана."
            }
            if !capturedUsableStem {
                return "Стем системного звука пуст — удалённая сторона не записана."
            }
            return nil
        }

        var logLine: String {
            let size = outputFileSizeBytes.map(String.init) ?? "missing"
            return "callbacks=\(callbackCount) pcm=\(pcmBufferCount) conversionFailures=\(conversionFailureCount) frames=\(framesWritten) audibleBuffers=\(audibleBufferCount) maxRMS=\(String(format: "%.5f", maxRMSLevel)) maxPeak=\(String(format: "%.5f", maxPeakLevel)) fileBytes=\(size)"
        }
    }

    /// Start capturing system audio into `url`, scoped to `targetBundleIdentifiers`
    /// when any of those apps is running (default: known meeting apps). Falls
    /// back to whole-display capture if none of them are running, or — via the
    /// watchdog — if the app-scoped stream produces no audio at all.
    func start(outputURL url: URL, targetBundleIdentifiers: [String] = SystemAudioCapture.meetingAppBundleIDs) async throws {
        guard !isRunning else { throw CaptureError.alreadyRunning }

        // Pre-flight: check Screen Recording permission (TCC).
        // Don't throw — just log and request. On some macOS versions SCK works even
        // when preflight returns false, and the watchdog will catch real failures.
        if !CGPreflightScreenCaptureAccess() {
            debugLog("[SystemAudioCapture] CGPreflight returned false — requesting access, will attempt capture anyway")
            CGRequestScreenCaptureAccess()
        } else {
            debugLog("[SystemAudioCapture] Screen Recording permission confirmed")
        }

        outputURL = url
        didStopWriting = false
        audioFile = nil
        try await startStream(targetBundleIdentifiers: targetBundleIdentifiers)
    }

    /// Builds the content filter (app-scoped if possible), starts the SCStream,
    /// and arms the watchdog. Shared by the initial start and the display-wide
    /// fallback restart, both of which use the same `outputURL`.
    private func startStream(targetBundleIdentifiers: [String]) async throws {
        debugLog("[SystemAudioCapture] Starting — requesting shareable content...")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        debugLog("[SystemAudioCapture] Got content: \(content.displays.count) displays, \(content.applications.count) apps")
        guard let display = Self.preferredDisplay(from: content) else {
            throw CaptureError.noDisplays
        }
        debugLog("[SystemAudioCapture] Selected display \(display.displayID) for capture filter")

        let targetApps = content.applications.filter { targetBundleIdentifiers.contains($0.bundleIdentifier) }
        let filter: SCContentFilter
        if !targetApps.isEmpty {
            filter = SCContentFilter(display: display, including: targetApps, exceptingWindows: [])
            isAppScoped = true
            debugLog("[SystemAudioCapture] App-scoped filter: \(targetApps.map(\.bundleIdentifier))")
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            isAppScoped = false
            debugLog("[SystemAudioCapture] No target meeting app running — using display-wide filter")
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Minimise video overhead — SCK requires a video stream to exist, but we only tap audio.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5
        // Audio
        config.sampleRate = 48_000
        config.channelCount = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        self.stream = stream

        debugLog("[SystemAudioCapture] Starting capture stream...")
        try await stream.startCapture()
        debugLog("[SystemAudioCapture] Capture started successfully")
        isRunning = true

        armWatchdog()
    }

    /// If no audio samples arrive within 4 seconds, the stream is silently
    /// failing (common with stale TCC grants, or an app-scoped filter whose
    /// app isn't actually emitting audio yet). App-scoped failures get one
    /// automatic retry against the whole display before surfacing a warning.
    private func armWatchdog() {
        sampleWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.isRunning else { return }
            if self.callbackCount == 0 {
                if self.isAppScoped, !self.didFallBackToDisplayWide {
                    self.didFallBackToDisplayWide = true
                    debugLog("[SystemAudioCapture] App-scoped capture produced no audio after 4s — falling back to display-wide")
                    await self.fallBackToDisplayWide()
                    return
                }
                let message = "System audio stream started but no audio buffers arrived after 4 seconds"
                debugLog("[SystemAudioCapture] WARNING: \(message)")
                self.onCaptureIssueDetected?(message)
            } else if self.pcmBufferCount == 0, self.conversionFailureCount > 0 {
                let message = "System audio buffers arrived but PCM conversion is failing"
                debugLog("[SystemAudioCapture] WARNING: \(message)")
                self.onCaptureIssueDetected?(message)
            } else if self.audibleBufferCount == 0, self.isAppScoped, !self.didFallBackToDisplayWide {
                // Silent app-scoped stream → try display-wide, but do NOT warn:
                // meetings often start with no remote audio yet.
                self.didFallBackToDisplayWide = true
                debugLog("[SystemAudioCapture] App-scoped capture is silent after 4s — falling back to display-wide")
                await self.fallBackToDisplayWide()
            }
            // Digital silence with buffers flowing is healthy — no warning.
        }
    }

    /// Restart the stream with a whole-display filter after an app-scoped
    /// stream produced zero audio. Best-effort: if this also fails, surface
    /// the same "no audio" warning callers would have gotten anyway.
    private func fallBackToDisplayWide() async {
        if let stream {
            do { try await stream.stopCapture() } catch {
                debugLog("[SystemAudioCapture] fallback stopCapture error: \(error)")
            }
        }
        stream = nil
        isRunning = false

        do {
            try await startStream(targetBundleIdentifiers: [])
        } catch {
            let message = "System audio fallback to display-wide capture failed: \(error.localizedDescription)"
            debugLog("[SystemAudioCapture] \(message)")
            onCaptureIssueDetected?(message)
        }
    }

    func stop() async {
        sampleWatchdog?.cancel()
        sampleWatchdog = nil
        guard let stream = stream else {
            sampleQueue.sync {
                didStopWriting = true
                audioFile = nil
                outputURL = nil
            }
            return
        }
        do { try await stream.stopCapture() } catch {
            debugLog("[SystemAudioCapture] stopCapture error: \(error)")
        }
        isRunning = false
        self.stream = nil
        sampleQueue.sync {
            didStopWriting = true
            audioFile = nil
            outputURL = nil
        }
    }

    /// Returns true if at least one audio sample was seen during the capture.
    var capturedAnyAudio: Bool { didSeeAnySamples }

    func report() -> CaptureReport {
        let size: Int64? = outputURL.flatMap { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let value = attrs[.size] as? NSNumber else { return nil }
            return value.int64Value
        }
        return CaptureReport(
            callbackCount: callbackCount,
            pcmBufferCount: pcmBufferCount,
            conversionFailureCount: conversionFailureCount,
            framesWritten: framesWritten,
            audibleBufferCount: audibleBufferCount,
            maxRMSLevel: maxRMSLevel,
            maxPeakLevel: maxPeakLevel,
            outputFileSizeBytes: size
        )
    }

    // MARK: - SCStreamOutput

    private var callbackCount = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        callbackCount += 1
        // Log first few callbacks to diagnose format issues
        #if DEBUG
        if callbackCount <= 3 {
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            let ready = CMSampleBufferDataIsReady(sampleBuffer)
            let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
            let mediaType = fmtDesc.map { CMFormatDescriptionGetMediaType($0) } ?? 0
            debugLog("[SystemAudioCapture] callback #\(callbackCount): type=\(type.rawValue) ready=\(ready) samples=\(numSamples) mediaType=\(mediaType) (1 = audio)")
            if let fd = fmtDesc, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                debugLog("[SystemAudioCapture]   format: rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) bitsPerCh=\(asbd.mBitsPerChannel) bytesPerFrame=\(asbd.mBytesPerFrame) framesPerPacket=\(asbd.mFramesPerPacket) formatID=\(asbd.mFormatID)")
            }
        }
        #endif

        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let outputURL = outputURL else { return }

        guard let pcmBuffer = Self.pcmBuffer(from: sampleBuffer) else {
            conversionFailureCount += 1
            #if DEBUG
            if callbackCount <= 5 {
                debugLog("[SystemAudioCapture] pcmBuffer conversion FAILED for callback #\(callbackCount)")
            }
            #endif
            return
        }
        pcmBufferCount += 1
        framesWritten += Int(pcmBuffer.frameLength)
        #if DEBUG
        if callbackCount <= 3 {
            debugLog("[SystemAudioCapture] pcmBuffer OK: frames=\(pcmBuffer.frameLength) channels=\(pcmBuffer.format.channelCount)")
        }
        #endif
        let rms = Self.rmsLevel(pcmBuffer)
        let peak = Self.peakLevel(pcmBuffer)
        maxRMSLevel = max(maxRMSLevel, rms)
        maxPeakLevel = max(maxPeakLevel, peak)
        if Self.hasAudibleContent(pcmBuffer) {
            audibleBufferCount += 1
            didSeeAnySamples = true
            // Audible audio ends the start-up watchdog. Silence alone must not —
            // scoped→display-wide fallback still needs to run when Zoom is quiet
            // but another app is the real output source.
            sampleWatchdog?.cancel()
            sampleWatchdog = nil
        }
        if didStopWriting { return }

        // Everything downstream wants 16 kHz mono: the offline mix resamples to
        // it, the speaker split only measures energy per window, and the
        // "usable stem" check only looks at size. Storing ScreenCaptureKit's
        // native 48 kHz stereo Float32 cost 375 KB/s — a 49-minute meeting left
        // a 1080 MB stem beside a 90 MB mic stem, 12x for nothing. It also fed
        // the offline mix a gigabyte-sized read (M1).
        let writeBuffer = stemConversionDisabled ? pcmBuffer : (downsampledStem(pcmBuffer) ?? pcmBuffer)

        if audioFile == nil {
            do {
                // Converted buffers go to disk as Int16; a native-format fallback
                // keeps the stream's own settings.
                let settings = (writeBuffer === pcmBuffer)
                    ? writeBuffer.format.settings
                    : Self.stemFileSettings
                audioFile = try AVAudioFile(forWriting: outputURL, settings: settings)
            } catch {
                debugLog("[SystemAudioCapture] failed to create AVAudioFile: \(error)")
                onCaptureIssueDetected?("System audio file could not be created: \(error.localizedDescription)")
                return
            }
        }
        do { try audioFile?.write(from: writeBuffer) } catch {
            debugLog("[SystemAudioCapture] write error: \(error)")
            onCaptureIssueDetected?("System audio write failed: \(error.localizedDescription)")
        }

        if let cb = levelCallback {
            cb(rms)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        debugLog("[SystemAudioCapture] stream stopped with error: \(error)")
        isRunning = false
        onCaptureIssueDetected?(
            "System audio stream stopped unexpectedly: \(error.localizedDescription)"
        )
    }

    // MARK: - Helpers

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              let fmt = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: asbd.mSampleRate,
                  channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
                  interleaved: false
              ) else { return nil }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }
        pcm.frameLength = AVAudioFrameCount(numSamples)

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let channelCount = Int(fmt.channelCount)
        let inputBufferCount = isNonInterleaved ? channelCount : 1
        let ablPtr = AudioBufferList.allocate(maximumBuffers: inputBufferCount)
        defer { free(ablPtr.unsafeMutablePointer) }
        let ablSize = MemoryLayout<AudioBufferList>.size
            + (max(inputBufferCount, 1) - 1) * MemoryLayout<AudioBuffer>.stride

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr.unsafeMutablePointer,
            bufferListSize: ablSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        guard let dstBuffers = pcm.floatChannelData else { return nil }
        let frames = Int(pcm.frameLength)

        if isFloat, isNonInterleaved {
            for channel in 0..<min(channelCount, ablPtr.count) {
                guard let src = ablPtr[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                memcpy(dstBuffers[channel], src, frames * MemoryLayout<Float>.size)
            }
        } else if isFloat {
            guard let src = ablPtr[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
            for frame in 0..<frames {
                for channel in 0..<channelCount {
                    dstBuffers[channel][frame] = src[frame * channelCount + channel]
                }
            }
        } else if bitsPerChannel == 16, isNonInterleaved {
            for channel in 0..<min(channelCount, ablPtr.count) {
                guard let src = ablPtr[channel].mData?.assumingMemoryBound(to: Int16.self) else { continue }
                for frame in 0..<frames {
                    dstBuffers[channel][frame] = Float(src[frame]) / Float(Int16.max)
                }
            }
        } else if bitsPerChannel == 16 {
            guard let src = ablPtr[0].mData?.assumingMemoryBound(to: Int16.self) else { return nil }
            for frame in 0..<frames {
                for channel in 0..<channelCount {
                    dstBuffers[channel][frame] = Float(src[frame * channelCount + channel]) / Float(Int16.max)
                }
            }
        } else {
            return nil
        }
        return pcm
    }

    /// Format we hand to `AVAudioFile.write(from:)`.
    ///
    /// Float32, not Int16, even though the stem lands on disk as Int16:
    /// `AVAudioFile(forWriting:settings:)` always exposes a Float32
    /// `processingFormat` and asserts on anything else. Passing an Int16 buffer
    /// aborted the capture queue inside `ExtAudioFile::WriteInputProc`.
    /// The Int16 conversion is `AVAudioFile`'s job, driven by `stemFileSettings`.
    private static let stemProcessingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )

    /// What actually gets written: 16 kHz mono Int16, same as the mic stem.
    private static let stemFileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    /// Resample one capture buffer to the stem format, or nil to write natively.
    ///
    /// The converter is created once and reused: with sample-rate conversion it
    /// carries filter state across buffers, and a fresh one per callback would
    /// click at every boundary. Any failure permanently downgrades this
    /// recording to the native format rather than dropping audio — losing the
    /// far side of a call is far worse than a large file.
    private func downsampledStem(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = Self.stemProcessingFormat else { return nil }
        if input.format.sampleRate == target.sampleRate,
           input.format.channelCount == target.channelCount {
            return nil   // already what we want; let AVAudioFile handle bit depth
        }

        if stemConverter == nil || stemConverter?.inputFormat != input.format {
            guard let made = AVAudioConverter(from: input.format, to: target) else {
                debugLog("[SystemAudioCapture] no converter for \(input.format); writing native")
                stemConversionDisabled = true
                return nil
            }
            stemConverter = made
        }
        guard let converter = stemConverter else { return nil }

        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            stemConversionDisabled = true
            return nil
        }

        var supplied = false
        var convError: NSError?
        let status = converter.convert(to: output, error: &convError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else {
            conversionFailureCount += 1
            debugLog("[SystemAudioCapture] stem downsample failed: \(convError?.localizedDescription ?? "unknown"); writing native")
            stemConversionDisabled = true
            stemConverter = nil
            return nil
        }
        return output
    }

    static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sumSq: Float = 0
        let p = data[0]
        let stride = max(1, frames / 256)
        var count = 0
        for i in Swift.stride(from: 0, to: frames, by: stride) {
            sumSq += p[i] * p[i]
            count += 1
        }
        let rms = sqrtf(sumSq / Float(count))
        return min(1.0, rms * 3.0)
    }

    private static func hasAudibleContent(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.floatChannelData else { return false }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let threshold: Float = 0.0005
        for c in 0..<channels {
            let p = data[c]
            for i in stride(from: 0, to: frames, by: 64) {
                if abs(p[i]) > threshold { return true }
            }
        }
        return false
    }

    private static func peakLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0 else { return 0 }
        var peak: Float = 0
        for c in 0..<channels {
            let p = data[c]
            for i in stride(from: 0, to: frames, by: 16) {
                peak = max(peak, abs(p[i]))
            }
        }
        return min(1.0, peak)
    }

    private static func preferredDisplay(from content: SCShareableContent) -> SCDisplay? {
        let displays = content.displays
        guard !displays.isEmpty else { return nil }
        let displayIDs = displays.map { String($0.displayID) }.joined(separator: ",")
        debugLog("[SystemAudioCapture] Available display IDs: \(displayIDs)")

        if let mouseDisplayID = displayIDContainingMouse(),
           let display = displays.first(where: { $0.displayID == mouseDisplayID }) {
            debugLog("[SystemAudioCapture] Mouse is on display \(mouseDisplayID)")
            return display
        }

        let mainDisplayID = CGMainDisplayID()
        if let display = displays.first(where: { $0.displayID == mainDisplayID }) {
            debugLog("[SystemAudioCapture] Falling back to main display \(mainDisplayID)")
            return display
        }

        return displays.first
    }

    private static func displayIDContainingMouse() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens where NSMouseInRect(mouse, screen.frame, false) {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let value = screen.deviceDescription[key] as? NSNumber {
                return CGDirectDisplayID(value.uint32Value)
            }
        }
        return nil
    }

    enum CaptureError: LocalizedError {
        case alreadyRunning, noDisplays, screenRecordingDenied
        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "Захват системного звука уже идёт"
            case .noDisplays: return "Нет дисплеев для ScreenCaptureKit"
            case .screenRecordingDenied:
                return "Нет разрешения «Запись экрана». Если недавно пересобирали приложение, разрешение могло устареть. Откройте Системные настройки → Конфиденциальность и безопасность → Запись экрана, выключите и включите Propeller, затем перезапустите приложение."
        }
        }
    }
}
