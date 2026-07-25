import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// System-audio capture via Core Audio Process Taps (macOS 14.2+).
/// Pure audio path — no ScreenCaptureKit video pipeline. Prefers Zoom-only
/// mixdown when Zoom is running; otherwise global mix excluding ourselves.
///
/// Writes Float32 WAV at the tap's native rate (same stem contract as
/// `SystemAudioCapture` for offline mix). Uses
/// `AudioDeviceCreateIOProcIDWithBlock` — AVAudioEngine cannot target a
/// CATap aggregate (plan-optimization E4).
@available(macOS 14.2, *)
final class ProcessTapAudioCapture {
    static let meetingAppBundleIDs = ["us.zoom.xos"]

    private let ioQueue = DispatchQueue(label: "app.propeller.process-tap-io", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "app.propeller.process-tap-write")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?
    private var tapFormat: AVAudioFormat?
    /// When true, appendPCM must not recreate the WAV (would truncate the stem — C10).
    private var didStopWriting = false

    /// Stem path retained for `report()` after `stop()` clears the live handle.
    private var stemURL: URL?
    private var lastKnownFileBytes: Int64?

    private(set) var outputURL: URL?
    private(set) var isRunning = false
    private(set) var isAppScoped = false
    /// Only one scoped → global fallback per session.
    private var didFallBackToGlobal = false

    var levelCallback: ((Float) -> Void)?
    var onCaptureIssueDetected: ((String) -> Void)?
    /// Fired once when the first PCM frames are written (clears premature UI warnings).
    var onRecovered: (() -> Void)?

    private var callbackCount = 0
    private var framesWritten = 0
    private var audibleBufferCount = 0
    private var maxRMSLevel: Float = 0
    private var maxPeakLevel: Float = 0
    private var healthWatchdog: DispatchWorkItem?
    private var didNotifyRecovered = false

    typealias CaptureReport = SystemAudioCapture.CaptureReport

    func start(outputURL url: URL, targetBundleIdentifiers: [String] = meetingAppBundleIDs) async throws {
        guard !isRunning else { throw SystemAudioCapture.CaptureError.alreadyRunning }
        outputURL = url
        stemURL = url
        didStopWriting = false
        didFallBackToGlobal = false
        audioFile = nil
        resetCounters()

        // Return as soon as the tap is running. Do NOT gate on audible audio —
        // Zoom is often silent for the first seconds; treating that as failure
        // aborted capture and falsely showed "System audio not captured".
        try await startHardware(targetBundleIdentifiers: targetBundleIdentifiers)
        armHealthWatchdog()
    }

    func stop() async {
        healthWatchdog?.cancel()
        healthWatchdog = nil
        await stopHardwareOnly()
        writeQueue.sync {
            snapshotFileSizeLocked()
            audioFile = nil
            didStopWriting = true
            outputURL = nil
        }
        debugLog("[ProcessTap] stopped frames=\(framesWritten) audible=\(audibleBufferCount) fileBytes=\(lastKnownFileBytes.map(String.init) ?? "missing")")
    }

    func report() -> CaptureReport {
        let size = lastKnownFileBytes ?? stemURL.flatMap { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let value = attrs[.size] as? NSNumber else { return nil }
            return value.int64Value
        }
        return CaptureReport(
            callbackCount: callbackCount,
            pcmBufferCount: framesWritten > 0 ? callbackCount : 0,
            conversionFailureCount: 0,
            framesWritten: framesWritten,
            audibleBufferCount: audibleBufferCount,
            maxRMSLevel: maxRMSLevel,
            maxPeakLevel: maxPeakLevel,
            outputFileSizeBytes: size
        )
    }

    // MARK: - Hardware lifecycle

    private func startHardware(targetBundleIdentifiers: [String]) async throws {
        let processIDs = Self.processObjectIDs(forBundleIDs: targetBundleIdentifiers)
        let tapDescription: CATapDescription
        if !processIDs.isEmpty {
            tapDescription = CATapDescription(stereoMixdownOfProcesses: processIDs)
            isAppScoped = true
            debugLog("[ProcessTap] scoped to \(processIDs.count) meeting process(es)")
        } else if let selfOID = Self.translatePIDToProcessObject(ProcessInfo.processInfo.processIdentifier) {
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfOID])
            isAppScoped = false
            debugLog("[ProcessTap] global mix (exclude self)")
        } else {
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            isAppScoped = false
            debugLog("[ProcessTap] global mix")
        }
        tapDescription.name = "Propeller Meeting Audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        let tapUID = tapDescription.uuid.uuidString

        var createdTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &createdTap)
        guard tapStatus == noErr, createdTap != kAudioObjectUnknown else {
            throw CaptureError.tapCreateFailed(tapStatus)
        }
        tapID = createdTap

        guard var asbd = Self.tapStreamDescription(tapID: tapID) else {
            tearDownHardware()
            throw CaptureError.invalidTapFormat
        }
        guard let format = withUnsafePointer(to: &asbd, { AVAudioFormat(streamDescription: $0) }) else {
            tearDownHardware()
            throw CaptureError.invalidTapFormat
        }
        tapFormat = format

        guard let outputUID = Self.defaultOutputDeviceUID() else {
            tearDownHardware()
            throw CaptureError.noOutputDevice
        }

        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Propeller Tap Aggregate",
            kAudioAggregateDeviceUIDKey: "app.propeller.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]

        var createdAgg = AudioDeviceID(0)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &createdAgg)
        guard aggStatus == noErr, createdAgg != 0 else {
            tearDownHardware()
            throw CaptureError.aggregateCreateFailed(aggStatus)
        }
        aggregateID = createdAgg

        try await Task.sleep(nanoseconds: 100_000_000)

        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, inInputData, _, _, _ in
            self?.handleIO(inInputData)
        }
        guard procStatus == noErr, let procID else {
            tearDownHardware()
            throw CaptureError.ioProcFailed(procStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            tearDownHardware()
            throw CaptureError.deviceStartFailed(startStatus)
        }

        isRunning = true
        debugLog("[ProcessTap] started rate=\(format.sampleRate) ch=\(format.channelCount) scoped=\(isAppScoped)")
    }

    /// Stop IO without clearing stem path / report counters (used for fallback restart).
    private func stopHardwareOnly() async {
        guard isRunning || ioProcID != nil || tapID != kAudioObjectUnknown else { return }
        if let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        isRunning = false
        writeQueue.sync {
            snapshotFileSizeLocked()
            audioFile = nil
        }
        tearDownHardware()
    }

    /// Soft recovery only: scoped→global if zero frames, then warn if still dead.
    /// Never treat "silence" (frames growing, peak≈0) as failure — meetings start quiet.
    private func armHealthWatchdog() {
        healthWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            let frames = self.writeQueue.sync { self.framesWritten }
            // ~0.15s at 48 kHz mono — anything below this with YouTube/Zoom up
            // is a header-only / dead tap, not "quiet meeting".
            let healthy = frames >= 8_000
            if healthy {
                self.scheduleZeroFrameCheck(after: 30)
                return
            }
            if self.isAppScoped, !self.didFallBackToGlobal {
                self.didFallBackToGlobal = true
                NSLog("[ProcessTap] scoped tap weak after 4s (frames=\(frames)) — falling back to global mix")
                Task { [weak self] in
                    await self?.fallBackToGlobal()
                }
                return
            }
            let msg = "Process Tap produced no usable audio (frames=\(frames))."
            NSLog("[ProcessTap] WARNING: \(msg)")
            self.onCaptureIssueDetected?(msg)
        }
        healthWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func scheduleZeroFrameCheck(after: TimeInterval) {
        healthWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            let frames = self.writeQueue.sync { self.framesWritten }
            if frames == 0 {
                let msg = "Process Tap stopped writing audio mid-recording."
                NSLog("[ProcessTap] WARNING: \(msg)")
                self.onCaptureIssueDetected?(msg)
            }
            // No recurring "stall" check — quiet meetings don't always emit buffers.
        }
        healthWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
    }

    private func fallBackToGlobal() async {
        guard isRunning, let url = stemURL ?? outputURL else { return }
        healthWatchdog?.cancel()
        healthWatchdog = nil
        await stopHardwareOnly()
        writeQueue.sync {
            self.framesWritten = 0
            self.callbackCount = 0
            self.audibleBufferCount = 0
            self.didStopWriting = false
            self.audioFile = nil
            self.outputURL = url
        }
        do {
            try await startHardware(targetBundleIdentifiers: [])
            armHealthWatchdog()
            NSLog("[ProcessTap] global fallback started")
        } catch {
            NSLog("[ProcessTap] global fallback failed: \(error)")
            onCaptureIssueDetected?("Process Tap fallback failed: \(error.localizedDescription)")
        }
    }

    private func resetCounters() {
        callbackCount = 0
        framesWritten = 0
        audibleBufferCount = 0
        maxRMSLevel = 0
        maxPeakLevel = 0
        didNotifyRecovered = false
        lastKnownFileBytes = nil
    }

    private func snapshotFileSizeLocked() {
        guard let url = outputURL ?? stemURL else { return }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let value = attrs[.size] as? NSNumber {
            lastKnownFileBytes = value.int64Value
        }
    }

    // MARK: - IO

    private func handleIO(_ inInputData: UnsafePointer<AudioBufferList>?) {
        guard let inInputData, let format = tapFormat else { return }
        let ablPointer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard !ablPointer.isEmpty, let mData = ablPointer[0].mData else { return }

        callbackCount += 1
        let byteCount = Int(ablPointer[0].mDataByteSize)
        guard byteCount > 0 else { return }

        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let frameCapacity = AVAudioFrameCount(byteCount / bytesPerFrame)
        guard frameCapacity > 0 else { return }

        let pcmCopy = Data(bytes: mData, count: byteCount)

        pcmCopy.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
            let sampleCount = byteCount / MemoryLayout<Float>.size
            guard sampleCount > 0 else { return }
            var sumSq: Float = 0
            var peak: Float = 0
            for i in 0..<sampleCount {
                let v = base[i]
                sumSq += v * v
                peak = max(peak, abs(v))
            }
            let rms = sqrt(sumSq / Float(sampleCount))
            maxRMSLevel = max(maxRMSLevel, rms)
            maxPeakLevel = max(maxPeakLevel, peak)
            if peak > 0.0005 {
                audibleBufferCount += 1
            }
            levelCallback?(min(1, rms * 8))
        }

        writeQueue.async { [weak self] in
            self?.appendPCM(pcmCopy, frameCount: frameCapacity)
        }
    }

    private func appendPCM(_ data: Data, frameCount: AVAudioFrameCount) {
        guard !didStopWriting, let url = outputURL, let format = tapFormat else { return }
        do {
            if audioFile == nil {
                audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            buffer.frameLength = frameCount
            let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard let dst = abl[0].mData else { return }
            data.copyBytes(to: dst.assumingMemoryBound(to: UInt8.self), count: min(data.count, Int(abl[0].mDataByteSize)))
            try audioFile?.write(from: buffer)
            framesWritten += Int(frameCount)
            if !didNotifyRecovered, framesWritten > 0 {
                didNotifyRecovered = true
                DispatchQueue.main.async { [weak self] in
                    self?.onRecovered?()
                }
            }
        } catch {
            NSLog("[ProcessTap] write error: \(error)")
            onCaptureIssueDetected?("Process Tap failed to write system audio: \(error.localizedDescription)")
        }
    }

    private func tearDownHardware() {
        if aggregateID != 0 && aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: - Helpers

    private static func processObjectIDs(forBundleIDs bundleIDs: [String]) -> [AudioObjectID] {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard let bid = app.bundleIdentifier else { return false }
            return bundleIDs.contains(bid)
        }
        return apps.compactMap { translatePIDToProcessObject($0.processIdentifier) }
    }

    static func translatePIDToProcessObject(_ pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidCopy = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidCopy) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPtr,
                &size,
                &objectID
            )
        }
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private static func tapStreamDescription(tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd) == noErr else {
            return nil
        }
        return asbd
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var cfUID: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfUID) == noErr,
              let cfUID else { return nil }
        return cfUID.takeUnretainedValue() as String
    }

    enum CaptureError: LocalizedError {
        case tapCreateFailed(OSStatus)
        case aggregateCreateFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case noOutputDevice
        case invalidTapFormat

        var errorDescription: String? {
            switch self {
            case .tapCreateFailed(let s): return "Process Tap create failed (\(s))"
            case .aggregateCreateFailed(let s): return "Aggregate device create failed (\(s))"
            case .ioProcFailed(let s): return "IOProc create failed (\(s))"
            case .deviceStartFailed(let s): return "AudioDeviceStart failed (\(s))"
            case .noOutputDevice: return "No default output device for Process Tap aggregate"
            case .invalidTapFormat: return "Process Tap returned an invalid audio format"
            }
        }
    }
}
