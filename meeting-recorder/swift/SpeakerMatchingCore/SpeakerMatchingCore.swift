import AVFoundation
import Foundation

public enum AudioCaptureSource: String, Codable, CaseIterable {
    case microphone
    case system
    case mixed
    case unknown
}

public struct AudioSourceStemURLs: Equatable {
    public let microphoneURL: URL
    public let systemURL: URL

    public static func expectedSiblings(for finalAudioURL: URL) -> AudioSourceStemURLs {
        let dir = finalAudioURL.deletingLastPathComponent()
        let base = finalAudioURL.deletingPathExtension().lastPathComponent
        return AudioSourceStemURLs(
            microphoneURL: dir.appendingPathComponent("\(base).mic.wav"),
            systemURL: dir.appendingPathComponent("\(base).sys.wav")
        )
    }

    public var existingMicrophoneURL: URL? {
        FileManager.default.fileExists(atPath: microphoneURL.path) ? microphoneURL : nil
    }

    public var existingSystemURL: URL? {
        FileManager.default.fileExists(atPath: systemURL.path) ? systemURL : nil
    }
}

public struct AudioSourceEnergyReport: Equatable {
    public let microphoneEnergy: Double?
    public let systemEnergy: Double?
    public let source: AudioCaptureSource

    public var hasStemData: Bool {
        microphoneEnergy != nil || systemEnergy != nil
    }
}

public enum AudioEnergyAnalyzer {
    public static func meanSquare(url: URL, windows: [ClosedRange<Double>]) throws -> Double {
        try WindowedAudioEnergyAnalyzer(url: url).meanSquare(in: windows)
    }
}

public enum AudioSourceEnergyClassifier {

    /// The same moment, expressed in the system stem's own timeline.
    ///
    /// Windows come from the transcript, which is timed against the mix — and
    /// the mix runs on the microphone's clock, because that stem starts first.
    /// The system stem's file begins `offset` seconds later, so reading it with
    /// unshifted windows compares one speaker's words against a different
    /// half-second of the other stem. Clamped at zero: a window that starts
    /// before the system stem existed can only be read from its beginning.
    public static func systemWindows(
        _ windows: [ClosedRange<Double>],
        systemStemOffset: Double
    ) -> [ClosedRange<Double>] {
        guard systemStemOffset.isFinite, systemStemOffset > 0 else { return windows }
        return windows.compactMap { window in
            let lower = max(0, window.lowerBound - systemStemOffset)
            let upper = window.upperBound - systemStemOffset
            guard upper > lower else { return nil }
            return lower...upper
        }
    }

    public static func analyze(
        finalAudioURL: URL,
        windows: [ClosedRange<Double>],
        systemStemOffset: Double = 0,
        dominanceRatio: Double = 1.6,
        energyFloor: Double = 1e-9
    ) -> AudioSourceEnergyReport {
        let stems = AudioSourceStemURLs.expectedSiblings(for: finalAudioURL)
        let micEnergy = stems.existingMicrophoneURL.flatMap { try? AudioEnergyAnalyzer.meanSquare(url: $0, windows: windows) }
        let sysWindows = systemWindows(windows, systemStemOffset: systemStemOffset)
        let systemEnergy = sysWindows.isEmpty
            ? nil
            : stems.existingSystemURL.flatMap { try? AudioEnergyAnalyzer.meanSquare(url: $0, windows: sysWindows) }
        let source = classify(
            microphoneEnergy: micEnergy,
            systemEnergy: systemEnergy,
            dominanceRatio: dominanceRatio,
            energyFloor: energyFloor
        )
        return AudioSourceEnergyReport(
            microphoneEnergy: micEnergy,
            systemEnergy: systemEnergy,
            source: source
        )
    }

    public static func classify(
        microphoneEnergy: Double?,
        systemEnergy: Double?,
        dominanceRatio: Double = 1.6,
        energyFloor: Double = 1e-9
    ) -> AudioCaptureSource {
        guard microphoneEnergy != nil || systemEnergy != nil else {
            return .unknown
        }

        let mic = microphoneEnergy ?? 0
        let system = systemEnergy ?? 0

        if mic <= energyFloor && system <= energyFloor {
            return .unknown
        }

        if system <= energyFloor {
            return .microphone
        }

        if mic <= energyFloor {
            return .system
        }

        if system >= mic * dominanceRatio {
            return .system
        }

        if mic >= system * dominanceRatio {
            return .microphone
        }

        return .mixed
    }
}

private final class WindowedAudioEnergyAnalyzer {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let sampleRate: Double
    private let channelCount: Int

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        format = file.processingFormat
        sampleRate = format.sampleRate
        channelCount = max(1, Int(format.channelCount))
    }

    func meanSquare(in windows: [ClosedRange<Double>]) throws -> Double {
        guard !windows.isEmpty else { return 0 }
        var sumSquares = 0.0
        var valueCount = 0

        for window in windows {
            let startSeconds = max(0, window.lowerBound)
            let endSeconds = max(startSeconds, window.upperBound)
            var startFrame = AVAudioFramePosition(startSeconds * sampleRate)
            let endFrame = min(AVAudioFramePosition(endSeconds * sampleRate), file.length)
            guard endFrame > startFrame else { continue }

            file.framePosition = startFrame
            while startFrame < endFrame {
                let framesToRead = min(AVAudioFrameCount(4096), AVAudioFrameCount(endFrame - startFrame))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                    break
                }
                try file.read(into: buffer, frameCount: framesToRead)
                let framesRead = Int(buffer.frameLength)
                guard framesRead > 0 else { break }

                if let floatData = buffer.floatChannelData {
                    for channel in 0..<channelCount {
                        let samples = floatData[channel]
                        for frame in 0..<framesRead {
                            let value = Double(samples[frame])
                            sumSquares += value * value
                            valueCount += 1
                        }
                    }
                } else if let int16Data = buffer.int16ChannelData {
                    for channel in 0..<channelCount {
                        let samples = int16Data[channel]
                        for frame in 0..<framesRead {
                            let value = Double(samples[frame]) / Double(Int16.max)
                            sumSquares += value * value
                            valueCount += 1
                        }
                    }
                }

                startFrame += AVAudioFramePosition(framesRead)
            }
        }

        guard valueCount > 0 else { return 0 }
        return sumSquares / Double(valueCount)
    }
}
