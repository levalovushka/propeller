import Foundation

/// Pure, dependency-free helpers covered by XCTest (plan-optimization S2).

public enum RecapMetadataParser {
    public struct Metadata: Equatable {
        public let title: String?
        public let topics: [String]
        public let tags: [String]
        public init(title: String?, topics: [String], tags: [String]) {
            self.title = title; self.topics = topics; self.tags = tags
        }
    }

    public static func parse(_ text: String, allowedTags: Set<String>) -> Metadata? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        let jsonStr = String(text[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let rawTitle = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String? = {
            guard let t = rawTitle, !t.isEmpty, t.lowercased() != "null" else { return nil }
            return t
        }()
        let topics = (obj["topics"] as? [Any])?
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let tags = (obj["tags"] as? [Any])?
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { allowedTags.contains($0) } ?? []
        return Metadata(title: title, topics: topics, tags: tags)
    }

    public static func stripCodeFences(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let firstNL = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNL)...])
            }
            if t.hasSuffix("```") {
                t = String(t.dropLast(3))
            }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }
}

public enum DiarizationMerge {
    /// Midpoint → "Speaker N" (same rules as TranscriptionService merge).
    public static func speakerLabel(
        forMidpoint midpoint: Float,
        diarization: [(id: String, start: Float, end: Float)]
    ) -> String {
        if let match = diarization.first(where: { midpoint >= $0.start && midpoint <= $0.end }) {
            return "Speaker \(match.id)"
        }
        if let closest = diarization.min(by: {
            abs(($0.start + $0.end) / 2 - midpoint) < abs(($1.start + $1.end) / 2 - midpoint)
        }) {
            return "Speaker \(closest.id)"
        }
        return "Speaker"
    }
}

public enum MixGain {
    /// Offline mic+system mix gain clamp.
    public static func systemMixGain(
        micRMS: Float, micPeak: Float,
        systemRMS: Float, systemPeak: Float
    ) -> Float {
        guard systemRMS > 0.0002, systemPeak > 0.0005 else { return 1 }
        let targetRMS = max(0.03, min(0.08, micRMS * 0.9))
        let rmsGain = targetRMS / systemRMS
        let peakLimitedGain = 0.90 / max(systemPeak, 0.0001)
        return min(max(1, rmsGain), min(4, peakLimitedGain))
    }
}

public enum WavHeader {
    /// Duration in seconds from a standard PCM WAV header (44-byte).
    public static func duration(url: URL) -> Double {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? fh.close() }
        guard let header = try? fh.read(upToCount: 44), header.count >= 44 else { return 0 }
        let sampleRate = header.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
        let bitsPerSample = header.subdata(in: 34..<36).withUnsafeBytes { $0.load(as: UInt16.self) }
        let numChannels = header.subdata(in: 22..<24).withUnsafeBytes { $0.load(as: UInt16.self) }
        guard sampleRate > 0, bitsPerSample > 0, numChannels > 0 else { return 0 }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let dataSize = max(0, Int(fileSize) - 44)
        let bytesPerSample = Int(bitsPerSample) / 8 * Int(numChannels)
        guard bytesPerSample > 0 else { return 0 }
        return Double(dataSize) / Double(bytesPerSample) / Double(sampleRate)
    }
}

public enum RecordingRecovery {
    /// Status transitions for interrupted recordings (mirrors RecordingStore).
    public static func recoveredStatus(current: String, hasTranscript: Bool) -> String? {
        switch current {
        case "recording": return "recorded"
        case "transcribing": return hasTranscript ? "transcribed_raw" : "recorded"
        default: return nil
        }
    }
}

/// Client-side chunking for gigastt REST (body-limit ~50 MiB + ~30 min file cap).
public enum GigasttChunking {
    /// Stay under default `--body-limit-bytes` (52 428 800) with headroom.
    public static let maxSingleShotBytes: Int64 = 45 * 1024 * 1024
    /// Stay under gigastt 2.14 file-duration cap (~30 min).
    public static let maxSingleShotSeconds: Double = 25 * 60
    /// Chunk length for long meetings (~38 MiB at 16 kHz mono PCM16).
    public static let chunkSeconds: Double = 20 * 60

    public static func needsChunking(fileBytes: Int64, durationSeconds: Double) -> Bool {
        fileBytes > maxSingleShotBytes || durationSeconds > maxSingleShotSeconds
    }

    public struct Segment: Equatable {
        public var start: Float
        public var end: Float
        public var text: String
        public init(start: Float, end: Float, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public static func applyOffset(_ segments: [Segment], offsetSeconds: Float) -> [Segment] {
        segments.map {
            Segment(start: $0.start + offsetSeconds, end: $0.end + offsetSeconds, text: $0.text)
        }
    }

    public static func merge(_ chunks: [(offset: Float, segments: [Segment])]) -> [Segment] {
        chunks.flatMap { applyOffset($0.segments, offsetSeconds: $0.offset) }
            .sorted { $0.start < $1.start }
    }
}
