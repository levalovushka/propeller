import AVFoundation
import Foundation

/// File playback for meeting detail / karaoke.
///
/// Uses `AVAudioEngine` + `AVAudioPlayerNode` so audio goes to the system
/// default output. `AVAudioPlayer` often advances time silently after Voice
/// Processing / Process Tap / SCK leave the HAL in a weird state.
@MainActor
class AudioPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var totalDuration: TimeInterval = 0
    @Published var progress: Double = 0
    @Published var errorMessage = ""

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioFile: AVAudioFile?
    private var loadedURL: URL?
    private var sampleRate: Double = 16_000
    private var fileLengthFrames: AVAudioFramePosition = 0
    /// File frame where the current `scheduleSegment` started.
    private var scheduledStartFrame: AVAudioFramePosition = 0
    private var timerTask: Task<Void, Never>?
    private var nodeAttached = false

    func play(url: URL) {
        errorMessage = ""
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "File not found: \(url.lastPathComponent)"
            return
        }
        if loadedURL == url, audioFile != nil {
            seek(toSeconds: 0)
            _ = resume()
            return
        }
        guard bind(url: url) else { return }
        _ = resume()
    }

    func pause() {
        guard isPlaying else { return }
        refreshTimeFromNode()
        playerNode.pause()
        isPlaying = false
        stopTimer()
    }

    @discardableResult
    func resume() -> Bool {
        guard let file = audioFile else {
            isPlaying = false
            return false
        }
        do {
            try ensureEngineRunning()
        } catch {
            errorMessage = "Audio engine: \(error.localizedDescription)"
            isPlaying = false
            return false
        }

        let frame = clampedFrame(for: currentTime)
        let remaining = AVAudioFrameCount(max(0, fileLengthFrames - frame))
        guard remaining > 0 else {
            isPlaying = false
            return false
        }

        playerNode.stop()
        scheduledStartFrame = frame
        playerNode.scheduleSegment(
            file,
            startingFrame: frame,
            frameCount: remaining,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Only mark ended if we actually reached (near) the end.
                if self.currentTime >= self.totalDuration - 0.15 {
                    self.isPlaying = false
                    self.currentTime = self.totalDuration
                    self.progress = 1
                    self.stopTimer()
                }
            }
        }
        playerNode.volume = 1.0
        engine.mainMixerNode.outputVolume = 1.0
        playerNode.play()
        isPlaying = true
        startTimer()
        return true
    }

    func stop() {
        stopTimer()
        playerNode.stop()
        if engine.isRunning { engine.stop() }
        audioFile = nil
        loadedURL = nil
        isPlaying = false
        currentTime = 0
        totalDuration = 0
        progress = 0
        scheduledStartFrame = 0
        fileLengthFrames = 0
    }

    func seek(to fraction: Double) {
        guard totalDuration > 0 else { return }
        seek(toSeconds: max(0, min(1, fraction)) * totalDuration)
    }

    func seek(toSeconds seconds: TimeInterval) {
        guard audioFile != nil else { return }
        let wasPlaying = isPlaying || playerNode.isPlaying
        let t: TimeInterval
        if totalDuration > 0 {
            t = max(0, min(seconds, max(0, totalDuration - 0.05)))
        } else {
            t = max(0, seconds)
        }
        currentTime = t
        progress = totalDuration > 0 ? t / totalDuration : 0
        if wasPlaying {
            _ = resume()
        } else {
            playerNode.stop()
            isPlaying = false
            stopTimer()
        }
    }

    func load(url: URL) {
        errorMessage = ""
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "File not found: \(url.lastPathComponent)"
            stop()
            return
        }
        if loadedURL == url, audioFile != nil {
            totalDuration = Double(fileLengthFrames) / max(sampleRate, 1)
            return
        }
        _ = bind(url: url)
    }

    var currentTimeFormatted: String { formatTime(currentTime) }
    var totalDurationFormatted: String { formatTime(totalDuration) }
    var loadedFileURL: URL? { loadedURL }

    // MARK: - Private

    @discardableResult
    private func bind(url: URL) -> Bool {
        stopTimer()
        playerNode.stop()
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            sampleRate = format.sampleRate
            fileLengthFrames = file.length
            totalDuration = Double(file.length) / max(sampleRate, 1)
            audioFile = file
            loadedURL = url
            currentTime = 0
            progress = 0
            isPlaying = false
            scheduledStartFrame = 0

            if !nodeAttached {
                engine.attach(playerNode)
                nodeAttached = true
            } else {
                engine.disconnectNodeOutput(playerNode)
            }
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 1.0
            try ensureEngineRunning()
            NSLog("[AudioPlayer] loaded %@ (%.1fs, %.0f Hz, %d ch)",
                  url.lastPathComponent, totalDuration, sampleRate, format.channelCount)
            return true
        } catch {
            errorMessage = "Load error: \(error.localizedDescription)"
            NSLog("[AudioPlayer] load failed: \(error)")
            audioFile = nil
            loadedURL = nil
            totalDuration = 0
            return false
        }
    }

    private func ensureEngineRunning() throws {
        if engine.isRunning { return }
        // Prepare before start so the output HAL opens on the default device.
        engine.prepare()
        try engine.start()
    }

    private func clampedFrame(for seconds: TimeInterval) -> AVAudioFramePosition {
        let frame = AVAudioFramePosition((seconds * sampleRate).rounded())
        return max(0, min(frame, max(0, fileLengthFrames - 1)))
    }

    private func refreshTimeFromNode() {
        guard let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid else { return }
        let seconds = Double(scheduledStartFrame + playerTime.sampleTime) / max(playerTime.sampleRate, 1)
        if seconds.isFinite {
            currentTime = max(0, min(seconds, totalDuration))
            progress = totalDuration > 0 ? currentTime / totalDuration : 0
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func startTimer() {
        stopTimer()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { break }
                if self.isPlaying {
                    self.refreshTimeFromNode()
                    if !self.playerNode.isPlaying, self.currentTime >= self.totalDuration - 0.2 {
                        self.isPlaying = false
                        self.currentTime = self.totalDuration
                        self.progress = 1
                        break
                    }
                }
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}
