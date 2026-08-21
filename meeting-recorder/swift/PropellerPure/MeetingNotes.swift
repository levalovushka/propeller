import Foundation

/// # Notes, as a list
///
/// The comps draw notes as separate records with a composer above them. The
/// archive has held a single blob of text since the first version — the one the
/// ⌃⌥N overlay appends to during a call, and the one `MarkdownWriter` copies
/// into the «Заметки» block of the transcript.
///
/// So the list is the new truth and the blob stays as its rendering. Both are
/// written on every change: a build from before this change reads `notes` and
/// sees exactly what it always saw, and this build reads `noteItems` when they
/// exist and derives them from `notes` when they do not. Nothing has to be
/// migrated ahead of time, and nothing is lost by opening an old archive in a
/// new app or a new archive in an old one.
public struct MeetingNoteRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var text: String
    public var createdAt: Date
    /// Сколько секунд от начала записи. Nil у заметки, написанной не во время
    /// встречи, — и это не пропуск, а разные вещи.
    ///
    /// `createdAt` на этот вопрос не отвечает: это дата на часах, а место в
    /// расшифровке измеряется от первого кадра звука. Раньше время заметки
    /// существовало только как строка `[12:34] ` в начале её же текста —
    /// достаточно, чтобы прочесть, и бесполезно, чтобы поставить заметку
    /// рядом с репликой, у которой время — число (`startSeconds`).
    ///
    /// Optional и в модели, и в файле: архив, записанный прежней сборкой,
    /// декодируется без него.
    public var offsetSeconds: Double?

    public init(
        id: String = UUID().uuidString,
        text: String,
        createdAt: Date = Date(),
        offsetSeconds: Double? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.offsetSeconds = offsetSeconds
    }
}

public enum MeetingNotes {

    /// Split a legacy blob into records: one per blank-line-separated paragraph.
    ///
    /// A blank line is the only boundary a person actually types. Splitting on
    /// every newline would turn one bulleted note into five, which is worse than
    /// leaving them joined.
    public static func migrate(from blob: String?, at date: Date = Date()) -> [MeetingNoteRecord] {
        guard let blob, !blob.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return paragraphs(of: blob).enumerated().map { index, text in
            // Deterministic ids: the same blob migrated twice is the same list,
            // so a re-read cannot duplicate a note or lose a selection.
            MeetingNoteRecord(id: "legacy-\(index)", text: text, createdAt: date)
        }
    }

    /// The blob every older reader still sees.
    ///
    /// The timecode is rendered back into it. It used to be typed into the
    /// note's own text by the overlay, so it was in the blob by accident; now
    /// it is a field, and the blob has to look exactly as it always did — the
    /// markdown writer copies it into a file people keep, and the recap prompt
    /// reads it as anchors, where «в 12:34 решили» is half the anchor.
    public static func blob(from notes: [MeetingNoteRecord]) -> String {
        notes.map(line(of:)).joined(separator: "\n\n")
    }

    /// One note as it is written down: `[12:34] текст`, or just the text when
    /// there is no time to put on it.
    ///
    /// A note that already carries a stamp in its text — every note written
    /// before the field existed — is left exactly as it is. Stamping it again
    /// would give it two.
    public static func line(of note: MeetingNoteRecord) -> String {
        guard let offset = note.offsetSeconds, stamp(in: note.text) == nil else { return note.text }
        return "[\(Timecode.text(offset))] \(note.text)"
    }

    /// Where a note belongs on the timeline, and what it says once the stamp is
    /// off the front of it.
    ///
    /// Notes written before `offsetSeconds` existed carry their time as text.
    /// It is read here rather than written back: rewriting somebody's archive
    /// to suit a new field is a change nobody asked for, and this answers the
    /// same question without touching the file.
    public static func placed(_ note: MeetingNoteRecord) -> (seconds: Double?, text: String) {
        if let found = stamp(in: note.text) {
            return (note.offsetSeconds ?? found.seconds, found.rest)
        }
        return (note.offsetSeconds, note.text)
    }

    /// A leading `[12:34] ` / `[1:02:03] `, if the text opens with one.
    static func stamp(in text: String) -> (seconds: Double, rest: String)? {
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return nil }
        let inside = text[text.index(after: text.startIndex)..<close]
        let parts = inside.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Int(part), value >= 0, part.count <= 2 else { return nil }
            seconds = seconds * 60 + Double(value)
        }
        let rest = text[text.index(after: close)...].drop(while: { $0 == " " })
        return (seconds, String(rest))
    }

    /// Records for display: the stored list when there is one, otherwise the
    /// legacy blob read as a list.
    public static func resolved(items: [MeetingNoteRecord]?, blob: String?) -> [MeetingNoteRecord] {
        if let items { return items }
        return migrate(from: blob)
    }

    static func paragraphs(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
