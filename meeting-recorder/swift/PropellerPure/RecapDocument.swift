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
        notes: String?,
        participants: [String] = []
    ) -> String {
        var parts: [String] = []
        parts.append("Встреча: \(title.isEmpty ? "без названия" : title)")
        // The roster names the only legal assignees — with the call-window
        // journal the labels are real people for the first time, and the model
        // should copy their spelling instead of transliterating from memory.
        // One line plus one rule: prompt length competes with completeness
        // (the extraction prompt's own lesson), so this earns exactly two.
        if !participants.isEmpty {
            parts.append("Участники: \(participants.joined(separator: ", ")).")
            parts.append("Исполнителем задачи может быть только участник из этого списка, и только если поручение прозвучало вслух.")
        }
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

    /// Who was in the meeting, read off the transcript's own speaker labels.
    ///
    /// Placeholder labels are not people, and the question of which labels those
    /// are is asked in exactly one place — `SourceAwareSpeaker.isPlaceholder`,
    /// next to the code that emits them. A meeting the journal never named
    /// therefore contributes no roster at all, and the prompt stays exactly as
    /// it was. Order of first appearance, no duplicates.
    ///
    /// This used to carry its own regex, which is how «Я» slipped through until
    /// the review of 2026-08-20: a meeting without clustering handed the prompt
    /// a participant called «Я», against which the model then checked names.
    public static func participants(fromTranscript transcript: String) -> [String] {
        let pattern = #"(?m)^\[([^\]\n]{1,60})\] \[\d{1,3}:\d{2}\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(transcript.startIndex..., in: transcript)
        var seen = Set<String>()
        var out: [String] = []
        regex.enumerateMatches(in: transcript, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let labelRange = Range(match.range(at: 1), in: transcript) else { return }
            let label = transcript[labelRange].trimmingCharacters(in: .whitespaces)
            guard !SourceAwareSpeaker.isPlaceholder(label), !seen.contains(label) else { return }
            seen.insert(label)
            out.append(label)
        }
        return out
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
