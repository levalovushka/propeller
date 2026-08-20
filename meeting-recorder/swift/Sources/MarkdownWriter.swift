import Foundation
import PropellerMetrics
import PropellerPure

/// The world around `MeetingMarkdown`: where the file goes, what today is, and
/// which people have a page in somebody's vault. The rendering itself lives in
/// `PropellerPure/MeetingMarkdown.swift`, where a test can reach it.
struct MarkdownWriter {

    static func save(
        title: String,
        transcript: String,
        recordingID: String,
        duration: TimeInterval,
        speakers: [String] = [],
        notes: String? = nil,
        calendarMeta: CalendarMeta? = nil,
        format: MarkdownOutputFormat = Preferences.shared.markdownOutputFormat
    ) throws -> String {
        let prefs = Preferences.shared
        let dir = URL(fileURLWithPath: prefs.meetingsPath)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let slug = MeetingMarkdown.slugify(title.isEmpty ? recordingID : title)
        let filename = "\(recordingID)-\(slug).md"
        let filepath = dir.appendingPathComponent(filename)

        // On rename + re-save, drop the transcript written under the old slug.
        // Same matcher as every other transcript/recap lookup (`RecapFile`).
        if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in contents
            where RecapFile.isTranscript(file.lastPathComponent, for: recordingID)
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
            calendarMeta: calendarMeta,
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
        calendarMeta: CalendarMeta? = nil,
        format: MarkdownOutputFormat = Preferences.shared.markdownOutputFormat
    ) -> String {
        PipelineMetrics.interval(PipelineMetrics.pipeline, PipelineMetrics.markdown) {
            MeetingMarkdown.render(
                title: title,
                transcript: transcript,
                recordingID: recordingID,
                duration: duration,
                speakers: speakers,
                notes: notes,
                calendarMeta: calendarMeta,
                format: format,
                today: todayISO(),
                // Only the Obsidian format links people, and only it pays for
                // walking somebody's vault.
                linkedSpeakers: format == .obsidian ? resolveLinkedSpeakers(speakers) : []
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
        MeetingMarkdown.simple(
            title: title,
            transcript: transcript,
            duration: duration,
            speakers: speakers.isEmpty ? MeetingMarkdown.extractSpeakers(from: transcript) : speakers,
            notes: notes,
            today: todayISO()
        )
    }

    // MARK: - Somebody else's folder

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
            let slug = MeetingMarkdown.speakerSlug(name)
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

    // MARK: - The clock

    private static func todayISO() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
