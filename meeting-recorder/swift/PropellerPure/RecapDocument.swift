import Foundation

/// What the model is asked, and what the person is left with.
///
/// Both used to sit in the executable target, and both used to accept
/// `speakers` and `duration` and throw them away on the first line (`_ =
/// speakers`). Four arguments threaded through two call sites to be discarded —
/// which is what happens to a signature nobody can write a test against.
public enum RecapDocument {

    /// The user half of the prompt: what meeting, what the person wrote down
    /// themselves, and the transcript.
    ///
    /// Notes come **before** the transcript and say so out loud, because a note
    /// is the one part of the input a human chose to write: when the two
    /// disagree, the note is the anchor and the transcript is the chatter.
    public static func userMessage(
        title: String,
        transcriptMarkdown: String,
        notes: String?
    ) -> String {
        var parts: [String] = []
        parts.append("Встреча: \(title.isEmpty ? "без названия" : title)")
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedNotes.isEmpty {
            parts.append("")
            parts.append("Заметки пользователя (якоря — приоритетнее болтовни в транскрипте):")
            parts.append(trimmedNotes)
        }
        parts.append("")
        parts.append("Транскрипт:")
        parts.append(transcriptMarkdown)
        parts.append("")
        parts.append("Ответь строго на русском языке.")
        return parts.joined(separator: "\n")
    }

    /// The recap file around the model's answer.
    ///
    /// Notes are not the tail of the file but a section under «Итог»: where they
    /// go is `RecapNotes`, and it is also what stops them appearing twice when
    /// the model wrote a section of its own. The text stays verbatim — the model
    /// never rewrites what a person typed.
    public static func wrapped(
        title: String,
        recapBody: String,
        notes: String?,
        format: MarkdownOutputFormat
    ) -> String {
        let heading = title.isEmpty ? "Meeting recap" : "\(title) — рекап"
        let body = RecapNotes.placed(notes, into: recapBody)

        var lines: [String] = []
        switch format {
        case .simple:
            lines.append("# \(heading)")
            lines.append("")
            lines.append(body)
        case .obsidian:
            let safeTitle = heading.replacingOccurrences(of: "\"", with: "'")
            lines.append("---")
            lines.append("title: \"\(safeTitle)\"")
            lines.append("tags: [meeting, recap]")
            lines.append("---")
            lines.append("")
            lines.append(body)
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }
}
