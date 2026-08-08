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

    public init(id: String = UUID().uuidString, text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
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
    public static func blob(from notes: [MeetingNoteRecord]) -> String {
        notes.map(\.text).joined(separator: "\n\n")
    }

    /// Records for display: the stored list when there is one, otherwise the
    /// legacy blob read as a list.
    public static func resolved(items: [MeetingNoteRecord]?, blob: String?) -> [MeetingNoteRecord] {
        if let items { return items }
        return migrate(from: blob)
    }

    /// The order the column shows them in: newest first.
    ///
    /// Storage stays chronological — the blob is what `MarkdownWriter` pours
    /// into the «Заметки» block of a transcript, and a transcript reads
    /// forward. Only the reading on screen is reversed, and it has to be: the
    /// composer sits at the top, so a note written there appearing at the
    /// bottom of a long list is a note you have to go looking for right after
    /// writing it.
    public static func newestFirst(_ notes: [MeetingNoteRecord]) -> [MeetingNoteRecord] {
        notes.reversed()
    }

    static func paragraphs(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
