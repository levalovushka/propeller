import Foundation

public enum MarkdownOutputFormat: String, CaseIterable, Identifiable, Sendable {
    case simple
    case obsidian

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .simple: return "Простой"
        case .obsidian: return "Obsidian"
        }
    }
}

/// The file a person keeps.
///
/// Everything here decides what the markdown says; nothing here touches the
/// disk, the clock or the preferences. That split is the point: this used to be
/// 253 lines inside an executable target, which meant the artefact the whole app
/// exists to produce was rendered by code no test could reach. The shell that
/// still owns the world — where the file goes, what today is, which people pages
/// exist — is `Sources/MarkdownWriter.swift`.
public enum MeetingMarkdown {

    public static func render(
        title: String,
        transcript: String,
        recordingID: String = "",
        duration: TimeInterval = 0,
        speakers: [String] = [],
        notes: String? = nil,
        calendarMeta: CalendarMeta? = nil,
        format: MarkdownOutputFormat,
        today: String,
        linkedSpeakers: [(String, String)] = []
    ) -> String {
        switch format {
        case .simple:
            return simple(
                title: title,
                transcript: transcript,
                duration: duration,
                speakers: speakers,
                notes: notes,
                calendarMeta: calendarMeta,
                today: today
            )
        case .obsidian:
            return obsidian(
                title: title,
                transcript: transcript,
                recordingID: recordingID,
                duration: duration,
                speakers: speakers,
                notes: notes,
                calendarMeta: calendarMeta,
                today: today,
                linkedSpeakers: linkedSpeakers
            )
        }
    }

    // MARK: - Simple

    public static func simple(
        title: String,
        transcript: String,
        duration: TimeInterval,
        speakers: [String],
        notes: String?,
        calendarMeta: CalendarMeta? = nil,
        today: String
    ) -> String {
        let heading = title.isEmpty ? "Meeting" : title
        let durationStr = duration > 0 ? "\(Int(duration / 60)) min" : ""

        var lines: [String] = []
        lines.append("# \(heading)")
        lines.append("")
        lines.append("**Date:** \(today)")
        if !durationStr.isEmpty {
            lines.append("**Duration:** \(durationStr)")
        }
        if !speakers.isEmpty {
            lines.append("**Participants:** \(speakers.joined(separator: ", "))")
        }
        if let calendarMeta, !calendarMeta.isEmpty {
            lines.append(contentsOf: calendarMeta.plainHeaderLines)
        }
        lines.append("")

        if let notes = notes, !notes.isEmpty {
            lines.append("## Notes")
            lines.append("")
            lines.append(notes)
            lines.append("")
        }

        lines.append("## Transcript")
        lines.append("")
        lines.append(transcriptBody(transcript))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Реплика на диске: `**Иван** · 12:34`.
    ///
    /// Одно определение на writer'а и всех читателей дискового вида. Раньше их
    /// было три отдельных выражения — здесь, в `TranscriptChunking` и в
    /// `RecapDocument.participants`, — и расхождение уже стоило инертного ростера
    /// в промпте (2026-08-20). Строится из `diskHeadBody`, чтобы форма имени и
    /// таймкода жила в одном месте, а анкеры и просмотр вперёд — производные.
    public static let diskHeadBody =
        #"\*\*([^*\n]{1,60})\*\*\s*·\s*(\d{1,3}:\d{2}(?::\d{2})?)"#

    /// Голова реплики целиком, от начала строки до конца.
    public static let diskHeadPattern = "^" + diskHeadBody + #"\s*$"#

    /// Та же голова как граница нарезки: где начинается следующая реплика.
    public static let diskTurnLookahead = "(?m)^(?=" + diskHeadBody + ")"

    /// Единственное место, где голова реплики собирается.
    public static func diskHead(speaker: String, timecode: String) -> String {
        "**\(speaker)** · \(timecode)"
    }

    /// `[Кто] [12:34]\nтекст` blocks into something a person reads. A block whose
    /// head is not a stamp keeps its words as they are: an unrecognised line is
    /// somebody's content, not noise to drop.
    public static func transcriptBody(_ transcript: String) -> String {
        let blocks = transcript.components(separatedBy: "\n\n")
        var out: [String] = []

        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lines = trimmed.components(separatedBy: "\n")
            guard let first = lines.first else { continue }

            if let regex = try? NSRegularExpression(pattern: Timecode.transcriptHeadPattern),
               let match = regex.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)),
               let nameR = Range(match.range(at: 1), in: first),
               let tsR = Range(match.range(at: 2), in: first) {
                let speaker = String(first[nameR])
                let ts = String(first[tsR])
                let text = lines.dropFirst().joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(diskHead(speaker: speaker, timecode: ts))
                if !text.isEmpty {
                    out.append(text)
                }
                out.append("")
            } else {
                out.append(trimmed)
                out.append("")
            }
        }

        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Obsidian

    /// `linkedSpeakers` is `(name, slug)` for the people who have a page in the
    /// vault. Which ones those are is a question about somebody's folder, so the
    /// answer arrives as an argument.
    public static func obsidian(
        title: String,
        transcript: String,
        recordingID: String,
        duration: TimeInterval,
        speakers: [String],
        notes: String?,
        calendarMeta: CalendarMeta? = nil,
        today: String,
        linkedSpeakers: [(String, String)]
    ) -> String {
        var linkedTranscript = transcript
        for (name, slugName) in linkedSpeakers {
            linkedTranscript = linkedTranscript.replacingOccurrences(
                of: "[\(name)]",
                with: "[[\(slugName)|\(name)]]"
            )
        }

        let durationStr = duration > 0 ? "\(Int(duration / 60)) min" : ""
        let audioFile = recordingID.isEmpty ? "" : "\(recordingID).wav"
        let safeTitle = title.replacingOccurrences(of: "\"", with: "'")

        let speakerEntries: [String] = speakers.map { name in
            if let (_, slugName) = linkedSpeakers.first(where: { $0.0 == name }) {
                return "\"[[\(slugName)|\(name)]]\""
            }
            return "\"\(name)\""
        }

        var lines: [String] = []
        lines.append("---")
        lines.append("date: \(today)")
        lines.append("title: \"\(safeTitle)\"")
        lines.append("duration: \"\(durationStr)\"")
        if !speakerEntries.isEmpty {
            lines.append("speakers: [\(speakerEntries.joined(separator: ", "))]")
        }
        lines.append("audio_file: \"\(audioFile)\"")
        if let calendarMeta, !calendarMeta.isEmpty {
            lines.append(contentsOf: calendarMeta.yamlFrontmatterLines)
        }
        lines.append("tags: [meeting]")
        lines.append("---")
        lines.append("")

        if let notes = notes, !notes.isEmpty {
            lines.append("## Notes")
            lines.append("")
            lines.append(notes)
            lines.append("")
        }

        lines.append("## Transcript")
        lines.append("")
        lines.append(linkedTranscript)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Names

    /// Slug for matching speaker names to people-page filenames: lowercase,
    /// spaces to dashes, everything else dropped.
    ///
    /// The alphabet is `\w`, not `a-z0-9`. With the ASCII class this function
    /// returned the empty string for every Cyrillic name — `speakerSlug("Левон")`
    /// → `""` — so in the archive this app is actually built for, linking a
    /// speaker to their page in an Obsidian vault could never match once. Latin
    /// names slug identically under both rules, so nothing that worked changes.
    public static func speakerSlug(_ name: String) -> String {
        name
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\w\s-]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Who spoke, read back out of the transcript's own block heads.
    ///
    /// A stand-in is not a name, and putting one in **Participants** would
    /// present it to a person as an attendee — in a file they keep, and in an
    /// Obsidian vault's frontmatter. Which labels are stand-ins is
    /// `SourceAwareSpeaker.isPlaceholder`, because the type that emits them is
    /// the one that should say so: this function used to know only about
    /// `Speaker …` and let «Собеседник» and «Я» — the labels of the path where
    /// diarization never ran at all — through.
    public static func extractSpeakers(from transcript: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: Timecode.transcriptHeadPattern,
            options: .anchorsMatchLines
        ) else { return [] }
        let range = NSRange(transcript.startIndex..., in: transcript)
        var names = Set<String>()
        regex.enumerateMatches(in: transcript, range: range) { match, _, _ in
            if let nameRange = match.flatMap({ Range($0.range(at: 1), in: transcript) }) {
                let name = String(transcript[nameRange])
                if !SourceAwareSpeaker.isPlaceholder(name) {
                    names.insert(name)
                }
            }
        }
        return names.sorted()
    }

    /// Slug for a filename built out of a meeting title.
    public static func slugify(_ text: String) -> String {
        text
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\w\s-]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[-\s]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
