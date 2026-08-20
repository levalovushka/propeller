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
        // Held to length here rather than at the row: the topics are persisted
        // and read by the pane too, and every backend arrives through this call.
        let topics = TopicText.tightened(
            (obj["topics"] as? [Any])?.compactMap { $0 as? String } ?? []
        )
        let tags = (obj["tags"] as? [Any])?
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { allowedTags.contains($0) } ?? []
        return Metadata(title: title, topics: topics, tags: tags)
    }

    /// Lift the first glyph — used on the joined subtitle, not on each topic.
    public static func capitalizingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
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

/// What a meeting says about itself in the rail, held to a length.
///
/// The topics are written by the model, and the prompt is what shapes them —
/// measured over the archive's own recaps it moved the average from 7.2 words a
/// topic to about four. What a prompt cannot do is bound the *worst* case: the
/// same prompt on the same summary, run twice, returned «гибридная модель
/// главной страницы с фокусом на Fast-play и Discovery через теги» on the second
/// pass. The rail has no line limit — a description that long is simply a row
/// six lines tall, pushing the rest of the day off screen.
///
/// So the shape is settled here rather than hoped for there.
public enum TopicText {

    /// Longest a topic is left alone. Two words above what the prompt asks for,
    /// deliberately: this is a guard against the outlier, not a second opinion
    /// about the wording. Six words is a slightly long line; twelve is a
    /// paragraph in a 300 pt rail.
    public static let wordBudget = 7

    /// The prompt asks for two or three. A model that returns six writes the row
    /// a list, so the extra ones are dropped rather than rendered.
    public static let maxTopics = 3

    /// Words that begin a tail rather than the thing itself. Cutting in front of
    /// one is exactly the compression the prompt describes — «отказ от
    /// дизайн-системы в пользу точного сетапа проекта» is about the refusal, and
    /// everything from «в пользу» on is the sentence explaining itself.
    private static let tailStarters: Set<String> = [
        "с", "со", "за", "в", "во", "для", "через", "вместо", "ради", "при",
        "по", "из", "от", "до", "о", "об", "обо", "на", "к", "ко", "у", "без",
        "под", "над", "про", "и", "а", "или", "чтобы", "что", "как", "где",
        "когда", "который", "которая", "которые",
    ]

    public static func tightened(_ topics: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for topic in topics {
            let tight = tightened(topic)
            guard !tight.isEmpty else { continue }
            // Two topics that compress to the same words say it once.
            guard seen.insert(tight.lowercased()).inserted else { continue }
            out.append(tight)
            if out.count == maxTopics { break }
        }
        return out
    }

    /// One topic, trimmed of the punctuation the prompt asked it not to add and
    /// of the tail it was asked not to write.
    ///
    /// A topic with no place to cut is left long. Half a phrase reads as a bug;
    /// a long one only reads as verbose, and the recap still has the full
    /// sentence.
    public static func tightened(_ topic: String) -> String {
        let words = topic
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return "" }

        var kept = words
        // The last word carries whatever the model put at the end of the phrase.
        kept[kept.count - 1] = trimmingTrailingPunctuation(kept[kept.count - 1])
        if kept[kept.count - 1].isEmpty { kept.removeLast() }
        guard kept.count > wordBudget else { return kept.joined(separator: " ") }

        // From index 2: a topic has to keep a subject, and «отказ от …» must not
        // be cut down to «отказ». The first boundary, not the last one that
        // would fit — cutting late leaves the preposition without its object
        // («… с фокусом»), which is worse than the long line it replaced.
        guard let cut = kept.indices.first(where: { index in
            index >= 2 && tailStarters.contains(kept[index].lowercased())
        }), cut <= wordBudget else {
            return kept.joined(separator: " ")
        }
        return kept[..<cut].joined(separator: " ")
    }

    private static func trimmingTrailingPunctuation(_ word: String) -> String {
        var out = word
        while let last = out.last, ".,;:…".contains(last) {
            out.removeLast()
        }
        return out
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

    /// Labels when there was no diarization at all — the stems are the only
    /// evidence there is.
    ///
    /// This is the plan B that keeps a transcript from being held hostage: the
    /// diarizer's models are fetched over the network, so a first run offline
    /// used to lose an ASR pass that had already succeeded
    /// (`design/no-dead-ends.md`, Э1).
    ///
    /// Only one thing can be *proved* from the stems: speech that arrived on the
    /// microphone is the owner's. Everything else came from the far side, and how
    /// many people are over there is exactly what we cannot know without
    /// clustering — so they are one name, not a guessed count. Overlap counts as
    /// the far side too: when both stems carry energy, someone over there is
    /// certainly talking, and «everyone is me» is the failure mode this whole
    /// file exists to avoid.
    public static func stemsOnly(
        source: Source,
        ownerName: String,
        remoteName: String = defaultRemoteName,
        ownerFallback: String = defaultOwnerName
    ) -> String {
        let owner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch source {
        case .microphone:
            return owner.isEmpty ? ownerFallback : owner
        case .system, .mixed, .unknown:
            return remoteName
        }
    }

    /// «Собеседник», singular: without clustering we cannot count the far side,
    /// and «Speaker 1» promises a numbering that has nothing behind it.
    public static let defaultRemoteName = "Собеседник"
    /// When the owner never entered a name in onboarding.
    public static let defaultOwnerName = "Я"

    /// Is this label a stand-in rather than somebody's name?
    ///
    /// Four kinds of stand-in exist and they come from two different places:
    /// `Speaker N` and bare `Speaker` from `DiarizationMerge.speakerLabel` when
    /// clustering ran but named nothing, and «Собеседник» / «Я» from
    /// `stemsOnly` when it never ran at all. Anything that presents a roster to
    /// a person has to ask this, and until 2026-08-20 three places asked it
    /// separately with three different answers — the markdown writer knew only
    /// about `Speaker …`, so «Собеседник» and «Я» were written into the file a
    /// person keeps, under **Participants**, as if they were attendees.
    ///
    /// Case-insensitive on purpose: the journal writes what a person typed into
    /// Zoom, and «собеседник» in lower case is the same non-name.
    public static func isPlaceholder(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        if trimmed.compare(defaultRemoteName, options: .caseInsensitive) == .orderedSame { return true }
        if trimmed.compare(defaultOwnerName, options: .caseInsensitive) == .orderedSame { return true }
        return trimmed.range(
            of: #"^(?:Speaker|Спикер)(?:\s*S?\d+)?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

/// How the speaker names in a transcript were arrived at.
///
/// Persisted on the recording, because it is a property of *that* transcript and
/// the card has to be able to say so: a dialogue split by stems is honest and
/// useful, and pretending it is the same thing as clustered speakers would be
/// the quiet kind of lying (`design/no-dead-ends.md` §7).
public enum SpeakerAttribution: String, Codable, Equatable, Sendable, CaseIterable {
    /// FluidAudio clustered the speech; names are per person.
    case diarized
    /// No clustering — owner by microphone, everyone else as one.
    case stems
    /// Names read from the call window's speaker label (`CallWindowJournal`),
    /// diarization filling the seconds the journal honestly declined. Appended,
    /// never renamed: the rawValue is on users' disks, and an older build
    /// decodes it as `.diarized` — a harmless degradation, both mean "speakers
    /// are named" (plan-speaker-tags.md §5).
    case callWindow

    /// Shown in the meeting's card. Nil when there is nothing to disclose.
    public var disclosure: String? {
        switch self {
        case .diarized: return nil
        case .stems:    return "Спикеры не разделены — только «я» и\u{00A0}собеседник"
        // Said plainly, because the person next to them could see the same
        // highlight (VISION §3.3) — and the unnamed remarks stay visibly
        // `Speaker N` in the feed itself, so the mixed origin is not hidden.
        case .callWindow: return "Имена спикеров — из окна Zoom"
        }
    }

    /// Unknown strings decode to `.diarized` rather than throwing: the same value
    /// `nil` already reads as (see `Models.speakerAttribution`), and a value we
    /// don't recognise must never cost the user their meeting (I6).
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SpeakerAttribution(rawValue: raw) ?? .diarized
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

/// Identifying our own ASR sidecar process among everything else running.
public enum SidecarProcess {
    /// Is this executable a `gigastt` shipped inside an app bundle — i.e. ours,
    /// from this build or a previous one?
    ///
    /// Used to free :9876 when a sidecar outlives the app that started it: after
    /// an update the PID file no longer matches, so the leftover process held the
    /// port and every launch failed until the user killed it by hand.
    ///
    /// Deliberately narrower than "named gigastt". A developer running
    /// `tools/gigastt/gigastt`, or anyone with their own install, must not have
    /// it killed out from under them — only `…/Something.app/Contents/MacOS/gigastt`
    /// counts, which is exactly what a stale sidecar still reports.
    public static func isBundledSidecar(path: String) -> Bool {
        let exe = path as NSString
        guard exe.lastPathComponent == "gigastt" else { return false }
        let macOS = exe.deletingLastPathComponent as NSString
        guard macOS.lastPathComponent == "MacOS" else { return false }
        return (macOS.deletingLastPathComponent as NSString).lastPathComponent == "Contents"
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

    /// Body limit the sidecar is launched with (`--body-limit-bytes`). Lives here
    /// so the client's chunk sizing and the server's limit cannot drift apart in
    /// two different files.
    public static let serverBodyLimitBytes: Int64 = 64 * 1024 * 1024

    /// Bytes a chunk occupies on disk. `bytesPerFrame` is what the WAV is
    /// *written* as — not what AVAudioFile decodes to in memory. Writing a
    /// 16 kHz Int16 mix out in its Float32 processing format doubled every
    /// chunk to 73.2 MiB and tripped the 64 MiB limit as HTTP 413.
    public static func chunkBytes(
        seconds: Double = chunkSeconds,
        sampleRate: Double,
        bytesPerFrame: Int
    ) -> Int64 {
        Int64(seconds * sampleRate) * Int64(bytesPerFrame)
    }

    public static func chunkFitsBodyLimit(sampleRate: Double, bytesPerFrame: Int) -> Bool {
        chunkBytes(sampleRate: sampleRate, bytesPerFrame: bytesPerFrame) <= serverBodyLimitBytes
    }

    public static func needsChunking(fileBytes: Int64, durationSeconds: Double) -> Bool {
        fileBytes > maxSingleShotBytes || durationSeconds > maxSingleShotSeconds
    }

    /// Shortest piece worth sending on its own.
    ///
    /// Halving stops here rather than at zero: below about half a minute the
    /// sidecar's own duration floor and the cost of a request per phrase start to
    /// dominate, and a 413 on a 30-second chunk is not a size problem any more —
    /// it is a broken sidecar, which the ladder handles.
    public static let minChunkSeconds: Double = 30

    /// What to do when the sidecar says a piece is too large.
    ///
    /// «Слишком большой кусок» is not a failure, it is an instruction: divide.
    /// The chunker sizes pieces from what it can measure, and it has been wrong
    /// before (a 16 kHz Int16 mix written back out as Float32 doubled every chunk
    /// and tripped the 64 MiB limit) — so the reply to 413 is to halve and go
    /// again, not to park a meeting with a red button on it
    /// (`design/no-dead-ends.md`, Э4).
    ///
    /// Returns the length to try next, or nil when halving has run out of room.
    public static func smallerChunk(after seconds: Double) -> Double? {
        let half = seconds / 2
        return half >= minChunkSeconds ? half : nil
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
