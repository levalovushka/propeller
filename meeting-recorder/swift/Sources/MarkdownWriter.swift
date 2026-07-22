import Foundation

enum MarkdownOutputFormat: String, CaseIterable, Identifiable {
    case simple
    case obsidian

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simple: return "Simple"
        case .obsidian: return "Obsidian"
        }
    }
}

struct MarkdownWriter {

    static func save(
        title: String,
        transcript: String,
        recordingID: String,
        duration: TimeInterval,
        speakers: [String] = [],
        notes: String? = nil,
        format: MarkdownOutputFormat = Preferences.shared.markdownOutputFormat
    ) throws -> String {
        let prefs = Preferences.shared
        let dir = URL(fileURLWithPath: prefs.meetingsPath)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let slug = slugify(title.isEmpty ? recordingID : title)
        let filename = "\(recordingID)-\(slug).md"
        let filepath = dir.appendingPathComponent(filename)

        // On rename + re-save, delete old file whose prefix matches the recordingID
        if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let prefix = recordingID + "-"
            for file in contents where file.pathExtension == "md"
                && file.lastPathComponent.hasPrefix(prefix)
                && file.lastPathComponent != filename {
                try? fm.removeItem(at: file)
            }
        }

        let content = render(
            title: title,
            transcript: transcript,
            recordingID: recordingID,
            duration: duration,
            speakers: speakers,
            notes: notes,
            format: format
        )
        try content.write(to: filepath, atomically: true, encoding: .utf8)
        return filepath.path
    }

    /// Build markdown for disk or clipboard without writing a file.
    static func render(
        title: String,
        transcript: String,
        recordingID: String = "",
        duration: TimeInterval = 0,
        speakers: [String] = [],
        notes: String? = nil,
        format: MarkdownOutputFormat = Preferences.shared.markdownOutputFormat
    ) -> String {
        switch format {
        case .simple:
            return renderSimple(
                title: title,
                transcript: transcript,
                duration: duration,
                speakers: speakers,
                notes: notes
            )
        case .obsidian:
            return renderObsidian(
                title: title,
                transcript: transcript,
                recordingID: recordingID,
                duration: duration,
                speakers: speakers,
                notes: notes
            )
        }
    }

    /// Clipboard-friendly body: always simple format (no YAML / wikilinks).
    static func chatClipboardText(
        title: String,
        transcript: String,
        duration: TimeInterval = 0,
        speakers: [String] = [],
        notes: String? = nil
    ) -> String {
        renderSimple(
            title: title,
            transcript: transcript,
            duration: duration,
            speakers: speakers.isEmpty ? extractSpeakers(from: transcript) : speakers,
            notes: notes
        )
    }

    // MARK: - Simple

    private static func renderSimple(
        title: String,
        transcript: String,
        duration: TimeInterval,
        speakers: [String],
        notes: String?
    ) -> String {
        let heading = title.isEmpty ? "Meeting" : title
        let durationStr = duration > 0 ? "\(Int(duration / 60)) min" : ""

        var lines: [String] = []
        lines.append("# \(heading)")
        lines.append("")
        lines.append("**Date:** \(todayISO())")
        if !durationStr.isEmpty {
            lines.append("**Duration:** \(durationStr)")
        }
        if !speakers.isEmpty {
            lines.append("**Participants:** \(speakers.joined(separator: ", "))")
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
        lines.append(formatTranscriptBodySimple(transcript))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Convert `[Speaker] [MM:SS]\nText` blocks into readable markdown.
    private static func formatTranscriptBodySimple(_ transcript: String) -> String {
        let blocks = transcript.components(separatedBy: "\n\n")
        var out: [String] = []

        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lines = trimmed.components(separatedBy: "\n")
            guard let first = lines.first else { continue }

            let pattern = #"^\[(.+?)\]\s*\[(\d+:\d+(?::\d+)?)\]$"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)),
               let nameR = Range(match.range(at: 1), in: first),
               let tsR = Range(match.range(at: 2), in: first) {
                let speaker = String(first[nameR])
                let ts = String(first[tsR])
                let text = lines.dropFirst().joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                out.append("**\(speaker)** · \(ts)")
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

    private static func renderObsidian(
        title: String,
        transcript: String,
        recordingID: String,
        duration: TimeInterval,
        speakers: [String],
        notes: String?
    ) -> String {
        let linkedSpeakers = resolveLinkedSpeakers(speakers)

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
        lines.append("date: \(todayISO())")
        lines.append("title: \"\(safeTitle)\"")
        lines.append("duration: \"\(durationStr)\"")
        if !speakerEntries.isEmpty {
            lines.append("speakers: [\(speakerEntries.joined(separator: ", "))]")
        }
        lines.append("audio_file: \"\(audioFile)\"")
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

    /// For each speaker name, check if a people page exists under peoplePagesPath.
    /// Returns array of (originalName, slug) for speakers that have a matching page.
    private static func resolveLinkedSpeakers(_ speakers: [String]) -> [(String, String)] {
        let pagesPath = Preferences.shared.peoplePagesPath
        guard !pagesPath.isEmpty else { return [] }

        let fm = FileManager.default
        let baseURL = URL(fileURLWithPath: pagesPath)
        guard fm.fileExists(atPath: baseURL.path) else { return [] }

        let knownSlugs = collectPageSlugs(under: baseURL)

        var result: [(String, String)] = []
        for name in speakers {
            let slug = speakerSlug(name)
            if knownSlugs.contains(slug) {
                result.append((name, slug))
            }
        }
        return result
    }

    /// Recursively collect all .md file stems (without extension) under a directory.
    private static func collectPageSlugs(under dir: URL) -> Set<String> {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var slugs = Set<String>()
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "md" {
                slugs.insert(fileURL.deletingPathExtension().lastPathComponent)
            }
        }
        return slugs
    }

    /// Slug for matching speaker names to people page filenames:
    /// lowercase, spaces to dashes, strip non-alphanumeric except dashes.
    static func speakerSlug(_ name: String) -> String {
        name
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\s-]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Extract unique speaker names from transcript text
    static func extractSpeakers(from transcript: String) -> [String] {
        // Transcript format: [Speaker Name] [MM:SS]
        let pattern = #"^\[(.+?)\] \[\d+:\d+\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
            return []
        }
        let range = NSRange(transcript.startIndex..., in: transcript)
        var names = Set<String>()
        regex.enumerateMatches(in: transcript, range: range) { match, _, _ in
            if let nameRange = match.flatMap({ Range($0.range(at: 1), in: transcript) }) {
                let name = String(transcript[nameRange])
                // Skip generic speaker labels
                if !name.hasPrefix("Speaker ") && name != "Speaker" {
                    names.insert(name)
                }
            }
        }
        return names.sorted()
    }

    // MARK: - Helpers

    private static func todayISO() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func slugify(_ text: String) -> String {
        text
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\w\s-]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[-\s]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
