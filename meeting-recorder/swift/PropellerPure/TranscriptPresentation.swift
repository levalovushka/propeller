import Foundation

/// A single transcribed line with its speaker attribution and timing.
///
/// Stored on `RecordingEntry.mergedSegmentsJSON` so per-segment speaker
/// reassignment stays possible: the transcript text alone is lossy — once a
/// speaker is renamed globally you can no longer tell which lines came from
/// which detected cluster.
public struct PersistedSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: Int { index }
    /// Stable identity in the segment list; survives edits so reassignment can
    /// address a line even after its text or speaker changed.
    public let index: Int
    public var startTime: Double
    public var endTime: Double
    public var text: String
    public var speaker: String

    public init(index: Int, startTime: Double, endTime: Double, text: String, speaker: String) {
        self.index = index
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
    }
}

/// Turns a transcript into what the screen shows: speaker turns, the phrases
/// inside them, and the words karaoke can seek on.
///
/// Pure on purpose. Every karaoke defect so far — "the whole remark highlights
/// at once", "clicks always jump to the start of the block", "one phrase per
/// turn" — was a bug in *this* logic, sitting inside a 2000-line view where
/// nothing could reach it. Here it is answerable by a test with a fixture.
public enum TranscriptPresentation {

    /// One ASR slice as displayed: the unit karaoke highlights and seeks to.
    public struct Phrase: Equatable, Sendable {
        public let startSeconds: Double
        public let endSeconds: Double
        public let text: String

        public init(startSeconds: Double, endSeconds: Double, text: String) {
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.text = text
        }
    }

    /// Consecutive phrases from one speaker, shown as a single block.
    public struct Turn: Equatable, Sendable {
        public let timestamp: String
        public let startSeconds: Double
        public let endSeconds: Double
        public let speaker: String
        public let phrases: [Phrase]
    }

    /// One word, carrying the timing of the phrase it belongs to. Words are the
    /// unit the text *wraps* on; phrases are the unit it *seeks* on.
    public struct Word: Identifiable, Equatable, Sendable {
        public let id: Int
        public let text: String
        public let startSeconds: Double
    }

    /// Gap between phrases of the same speaker that still reads as one turn.
    public static let turnGapSeconds: Double = 5.0

    // MARK: - Building turns

    /// Preferred path: real ASR segments, so phrases stay fine-grained and
    /// karaoke can highlight and seek within a remark.
    public static func turns(from segments: [PersistedSegment]) -> [Turn] {
        let slices = segments.compactMap { segment -> (Phrase, String)? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (
                Phrase(
                    startSeconds: segment.startTime,
                    endSeconds: max(segment.endTime, segment.startTime + 0.05),
                    text: text
                ),
                segment.speaker
            )
        }
        return merge(slices)
    }

    /// Fallback for recordings with no segment snapshot: parse the rendered
    /// text. One phrase per remark is all the timing this can recover, so
    /// karaoke is necessarily coarser — which is exactly what a lost snapshot
    /// costs, and why the snapshot is worth keeping.
    public static func turns(parsing transcript: String, duration: TimeInterval) -> [Turn] {
        let parsed = parseRemarks(transcript)
        let fallbackEnd = max(duration, parsed.last?.start ?? 0) + 1
        let slices = parsed.enumerated().map { index, remark -> (Phrase, String) in
            let end = index + 1 < parsed.count ? parsed[index + 1].start : fallbackEnd
            return (
                Phrase(
                    startSeconds: remark.start,
                    endSeconds: max(end, remark.start + 0.01),
                    text: remark.text
                ),
                remark.speaker
            )
        }
        return merge(slices)
    }

    /// Words of a turn, each pointing at its phrase's start.
    public static func words(in turn: Turn) -> [Word] {
        var words: [Word] = []
        for phrase in turn.phrases {
            for token in phrase.text.split(separator: " ") where !token.isEmpty {
                words.append(
                    Word(id: words.count, text: String(token), startSeconds: phrase.startSeconds)
                )
            }
        }
        return words
    }

    /// Distinct speakers in first-appearance order.
    public static func speakers(in turns: [Turn]) -> [String] {
        var seen = Set<String>()
        return turns.compactMap { turn in
            guard !turn.speaker.isEmpty, seen.insert(turn.speaker).inserted else { return nil }
            return turn.speaker
        }
    }

    // MARK: - Timestamps

    public static func formatTimestamp(_ seconds: Double) -> String {
        Timecode.text(seconds)
    }

    /// Nothing is not a time, and this caller would rather have a number than a
    /// decision: an unparseable head keeps its words at second zero.
    public static func parseTimestamp(_ text: String) -> Double {
        Timecode.seconds(text) ?? 0
    }

    // MARK: - Merging

    private static func merge(_ slices: [(Phrase, String)]) -> [Turn] {
        var turns: [Turn] = []
        for (phrase, speaker) in slices {
            if let last = turns.last,
               last.speaker == speaker,
               !speaker.isEmpty,
               phrase.startSeconds - last.endSeconds <= turnGapSeconds {
                turns[turns.count - 1] = Turn(
                    timestamp: last.timestamp,
                    startSeconds: last.startSeconds,
                    endSeconds: max(phrase.endSeconds, last.endSeconds),
                    speaker: last.speaker,
                    phrases: last.phrases + [phrase]
                )
            } else {
                turns.append(
                    Turn(
                        timestamp: formatTimestamp(phrase.startSeconds),
                        startSeconds: phrase.startSeconds,
                        endSeconds: phrase.endSeconds,
                        speaker: speaker,
                        phrases: [phrase]
                    )
                )
            }
        }
        return turns
    }

    // MARK: - Parsing rendered text

    private struct Remark {
        let speaker: String
        let text: String
        let start: Double
    }

    /// Current shape is `[Speaker] [MM:SS]\ntext`; the two older ones are still
    /// on disk in meetings recorded before it, so they have to keep parsing.
    private static func parseRemarks(_ transcript: String) -> [Remark] {
        var remarks: [Remark] = []
        for block in transcript.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let head = lines.first?.trimmingCharacters(in: .whitespaces), !head.isEmpty else {
                continue
            }

            if let match = capture(Timecode.transcriptHeadPattern, in: head) {
                let text = lines.dropFirst().joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                remarks.append(
                    Remark(speaker: match[0], text: text, start: parseTimestamp(match[1]))
                )
                continue
            }

            let legacy = [
                #"^\*{0,2}\[(\d+:\d+)\]\s*(.+?):\*{0,2}\s*(.*)"#,
                #"^\[(\d+:\d+)\]\s*(.+?):\s*(.*)"#,
            ]
            var matched = false
            for pattern in legacy {
                guard let match = capture(pattern, in: head) else { continue }
                let text = stripArtefacts(match[2])
                guard !text.isEmpty else { break }
                remarks.append(
                    Remark(speaker: match[1], text: text, start: parseTimestamp(match[0]))
                )
                matched = true
                break
            }
            // Unrecognised line: keep the words, lose the timing, rather than
            // silently dropping content the user can see in the file.
            if !matched {
                remarks.append(Remark(speaker: "", text: head, start: 0))
            }
        }
        return remarks
    }

    private static func stripArtefacts(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "**", with: "")
        // GigaAM emits control tokens like `<|spk1|>` in the older format.
        if let regex = try? NSRegularExpression(pattern: #"<\|[^|]*\|>"#) {
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: ""
            )
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Capture groups of the first match, or nil.
    private static func capture(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
