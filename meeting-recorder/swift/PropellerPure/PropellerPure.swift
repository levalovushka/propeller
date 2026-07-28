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
        guard let obj = decodeObject(jsonStr) ?? decodeObject(quotingBareArrayTokens(jsonStr)) else {
            return nil
        }

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

    private static func decodeObject(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Repair the one malformed shape these models actually produce: a bare
    /// token inside an array, e.g. `"tags": [1:1]` — our own `1:1` vocabulary
    /// entry emitted without quotes, which invalidates the whole object and
    /// costs the meeting its topics and tags.
    ///
    /// Ollama gets `format: "json"` and cannot hit this; the cloud providers
    /// have no such switch, so the repair stays as the shared backstop. Only
    /// array elements are touched, and only when strict parsing already failed.
    public static func quotingBareArrayTokens(_ json: String) -> String {
        var out = ""
        var inString = false, escaped = false, depth = 0
        var token = ""

        func flush() {
            let t = token.trimmingCharacters(in: .whitespaces)
            token = ""
            guard !t.isEmpty else { return }
            // Leave things that are already valid JSON scalars alone.
            let literals: Set<String> = ["true", "false", "null"]
            if literals.contains(t) || Double(t) != nil {
                out += t
            } else {
                out += "\"\(t)\""
            }
        }

        for ch in json {
            if inString {
                out.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true; out.append(ch)
            case "[": depth += 1; out.append(ch)
            case "]":
                if depth > 0 { flush() }
                depth = max(0, depth - 1); out.append(ch)
            case "," where depth > 0:
                flush(); out.append(ch)
            default:
                if depth > 0 { token.append(ch) } else { out.append(ch) }
            }
        }
        return out
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

/// Headphones / Zoom calls: FluidAudio often collapses mic+system into one
/// cluster. When stems exist, mic/sys energy is a stronger split than clustering.
public enum SourceAwareSpeaker {
    public enum Source: String {
        case microphone, system, mixed, unknown
    }

    /// `fluidDisplayName` is already owner-mapped (e.g. "leva" or "Speaker 1").
    public static func resolve(
        fluidDisplayName: String,
        source: Source,
        ownerName: String,
        remoteFallback: String = "Speaker 1"
    ) -> String {
        let owner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch source {
        case .microphone:
            return owner.isEmpty ? fluidDisplayName : owner
        case .system:
            // Never attribute headphone/system audio to the local owner —
            // that's the usual "everyone is me" failure mode.
            if !owner.isEmpty, fluidDisplayName.caseInsensitiveCompare(owner) == .orderedSame {
                return remoteFallback
            }
            if fluidDisplayName.isEmpty || fluidDisplayName == "Speaker" {
                return remoteFallback
            }
            return fluidDisplayName
        case .mixed, .unknown:
            return fluidDisplayName
        }
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
    /// Where an interrupted recording lands on the next launch. Nil means the
    /// stage is durable and needs no repair.
    public static func recoveredStage(
        current: RecordingStage,
        hasTranscript: Bool
    ) -> RecordingStage? {
        switch current {
        case .recording: return .recorded
        // ASR finished before the crash — keep the checkpoint so diarization
        // resumes instead of re-running an hour of GPU work.
        case .transcribing: return hasTranscript ? .transcribedRaw : .recorded
        default: return nil
        }
    }
}

/// Which model-pull failures are worth another attempt.
///
/// Ollama reports transport trouble as free text from its Go stack ("dial tcp:
/// lookup ... no such host", "unexpected EOF"), so classification is by message.
/// Getting the direction right matters more than precision: retrying a
/// permanent failure wastes ~17 minutes of silence before telling the user
/// anything, while not retrying a blip strands a 3.4 GB download.
public enum OllamaRetry {
    /// Same failure every time — the name is wrong, the disk is full, or we are
    /// not allowed. Checked first, because a permanent failure often surfaces
    /// wrapped in transport wording ("pull model manifest: ... manifest unknown"
    /// carries "manifest", "no space left" arrives mid-connection). DNS failure
    /// is deliberately NOT here: "no such host" means the link is down, which is
    /// exactly the case worth waiting out.
    static let permanentMarkers = [
        "manifest unknown", "file does not exist", "not found", "no space left",
        "unauthorized", "invalid model", "insufficient", "access denied",
    ]

    static let transientMarkers = [
        "connection", "timeout", "timed out", "eof", "reset by peer", "network",
        "temporarily", "tls", "handshake", "unreachable", "no such host",
        "dial tcp", "broken pipe", "i/o error",
    ]

    public static func isRetryable(message: String) -> Bool {
        let text = message.lowercased()
        if permanentMarkers.contains(where: text.contains) { return false }
        return transientMarkers.contains(where: text.contains)
    }
}

/// Context window sizing for the Ollama recap call.
///
/// Ollama picks the window per request. With no `num_ctx` it falls back to a ~4k
/// window and *slides* it (`--context-shift`), silently dropping the oldest
/// tokens — so the recap gets written from the tail of the meeting. Measured
/// 2026-07-27 on a 42-minute Russian call: 5538 prompt tokens, of which the
/// model actually saw 2050.
public enum OllamaContext {
    /// Russian transcripts measured ~2.6 characters per token on the Qwen
    /// tokenizer. Held deliberately low so the estimate errs toward a window
    /// that is too large rather than one that truncates.
    public static let charactersPerToken = 2.2

    /// Headroom reserved for the reply — `num_ctx` covers prompt *and*
    /// completion. Generation itself stays uncapped (no `num_predict`) so a long
    /// recap ends on EOS instead of being cut mid-sentence.
    public static let replyTokens = 3072

    /// Coarse on purpose: every distinct `num_ctx` makes Ollama spin up a fresh
    /// llama-server and pay a cold model load, so the common meeting must not
    /// straddle a boundary. 16k holds ~2 h of Russian speech; the second bucket
    /// exists for the rare all-day call.
    public static let buckets = [16384, 32768]

    public static func estimatedTokens(promptCharacters: Int) -> Int {
        Int((Double(max(0, promptCharacters)) / charactersPerToken).rounded(.up))
    }

    /// Window to request for a prompt of `promptCharacters`, clamped to the
    /// largest bucket.
    public static func numCtx(promptCharacters: Int) -> Int {
        let needed = estimatedTokens(promptCharacters: promptCharacters) + replyTokens
        return buckets.first { $0 >= needed } ?? buckets[buckets.count - 1]
    }

    /// True when even the largest bucket can't hold the prompt — the caller
    /// should say so out loud rather than ship a quietly truncated summary.
    public static func exceedsLargestWindow(promptCharacters: Int) -> Bool {
        estimatedTokens(promptCharacters: promptCharacters) + replyTokens > buckets[buckets.count - 1]
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
