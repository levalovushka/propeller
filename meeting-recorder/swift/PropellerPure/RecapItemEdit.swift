import Foundation

/// Surgical edits to one item of a recap document.
///
/// Editing a summary today rewrites the whole file: the editor hands back a
/// `SummaryDocument`, `SummaryDocument.markdown` builds the document again from
/// blocks, and `AppState.saveSummary` writes the result over the file. That is
/// a fair trade while the person is looking at the very document they touched —
/// heading levels, list indents, numbered lists and horizontal rules are
/// normalised in front of their eyes.
///
/// It stops being fair on the project screen. A checkbox there edits an item
/// that lives in *another* meeting's file, which nobody is looking at, so the
/// whole list of round-trip losses would be charged to a click the person reads
/// as "tick this box".
///
/// So this module never rebuilds a document. It finds an item exactly the way
/// `RecapDigest` finds it — same section folding, same three bullet markers,
/// same rule for continuation lines — and rewrites only the lines that item
/// occupies. Every other byte comes back unchanged.
///
/// A document with Windows line endings is read like any other, and the endings
/// it comes with are the endings it goes back with — the trailing `\r` rides
/// along on the line it belongs to.
///
/// This used to be a refusal, and the reason written down for it was wrong. The
/// story was «`RecapDigest` does not strip the carriage return, so the heading
/// reads as `Решения\r`». The truth is a layer below: in Swift `\r\n` is a
/// single `Character` and it is not `\n`, so `split(separator: "\n")` did not
/// split such a file **at all** — the whole document arrived as one line. Both
/// modules now cut with `components(separatedBy:)` and trim the carriage return.
///
/// Nothing here decides *what* an item means. The checkbox and the owner chip
/// are markup inside the item's text (`plan-projects.md` §4.1), and parsing
/// them is a separate job; this module only moves lines.
public enum RecapItemEdit {

    // MARK: - Where an item is

    /// One item of one section, and the lines it occupies in the source.
    public struct Location: Equatable, Sendable {
        /// Section heading as written, before folding.
        public let section: String
        /// Position of the section in the document, counted from zero over the
        /// sections `RecapDigest` would build. Two sections can carry the same
        /// title, and `RecapDigest.section(named:)` answers with the first —
        /// this is what lets a lookup agree with it.
        public let sectionOrdinal: Int
        /// Index of the item inside its section, in `RecapDigest` order.
        public let index: Int
        /// The item text `RecapDigest` would report, continuations included.
        public let text: String
        /// Source lines the item occupies: the bullet, plus every line glued
        /// onto it as a continuation.
        public let lines: ClosedRange<Int>
        /// Whether those lines are a solid run.
        ///
        /// `RecapDigest` keeps gluing unmarked lines onto the last item across
        /// blank lines, so a horizontal rule or a stray paragraph two lines
        /// below a list still counts as part of the last bullet. Reading it
        /// that way is harmless; *rewriting* those lines as one would delete a
        /// blank line and a rule the person never associated with the item, so
        /// an item like that is read but never edited.
        public let contiguous: Bool
        /// Leading spaces or tabs of the bullet line, kept so a nested item
        /// stays nested.
        public let indent: String
        /// The bullet marker as written — `- `, `* ` or `• `.
        public let marker: String
    }

    /// What the caller believes it is editing. The text is not decoration: it
    /// is the guard. The file may have been rewritten by the summary editor, by
    /// a re-generated recap or by Obsidian since the caller read it, and an
    /// index alone would then point at somebody else's sentence.
    public struct Target: Equatable, Sendable {
        public let section: String
        public let index: Int
        public let text: String

        public init(section: String, index: Int, text: String) {
            self.section = section
            self.index = index
            self.text = text
        }
    }

    /// Every item of the document, in reading order.
    ///
    /// Mirrors `RecapDigest.parse` line for line, so `locations(in:)` filtered
    /// by a section is the same list, in the same order, as
    /// `RecapDigest.parse(...).section(named:)?.items`.
    public static func locations(in markdown: String) -> [Location] {
        struct Draft {
            var text: String
            var start: Int
            var end: Int
            var contiguous: Bool
            var indent: String
            var marker: String
        }

        var out: [Location] = []
        var title: String?
        var ordinal = 0
        var drafts: [Draft] = []
        var paragraphOpen = false
        /// A blank line stands between the item and whatever comes next.
        var broken = false

        func flushSection() {
            defer {
                drafts.removeAll()
                paragraphOpen = false
            }
            // Anything before the first `##` is the document's name and its
            // surroundings. `RecapDigest` drops it, so it has no index to edit.
            guard let title else { return }
            for (index, draft) in drafts.enumerated() {
                out.append(Location(
                    section: title,
                    sectionOrdinal: ordinal,
                    index: index,
                    text: draft.text,
                    lines: draft.start...draft.end,
                    contiguous: draft.contiguous,
                    indent: draft.indent,
                    marker: draft.marker
                ))
            }
            ordinal += 1
        }

        // Режется и читается ровно как в `RecapDigest` — `components`, потому
        // что «\r\n» это один Character и `split(separator: "\n")` его не видит,
        // и с тем же снятием возврата каретки. Разойдись они здесь, и в
        // CRLF-документе один нашёл бы пункт, которого второй не видит.
        let lines = markdown.components(separatedBy: "\n")
        for (number, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            if let heading = RecapDigest.headingTitle(line) {
                flushSection()
                title = heading
                continue
            }
            if line.isEmpty {
                paragraphOpen = false
                broken = true
                continue
            }
            if let body = RecapDigest.bulletBody(line) {
                paragraphOpen = false
                broken = false
                drafts.append(Draft(
                    text: body,
                    start: number,
                    end: number,
                    contiguous: true,
                    indent: String(raw.prefix(while: { $0 == " " || $0 == "\t" })),
                    marker: marker(of: line)
                ))
                continue
            }
            // An unmarked line right after an item is its continuation, not a
            // new paragraph — the same rule `RecapDigest` applies.
            if !drafts.isEmpty, !paragraphOpen {
                drafts[drafts.count - 1].text += " " + line
                drafts[drafts.count - 1].end = number
                if broken { drafts[drafts.count - 1].contiguous = false }
                continue
            }
            paragraphOpen = true
            broken = false
        }
        flushSection()

        return out
    }

    /// The item a target points at, or `nil` when the document no longer holds
    /// it — wrong section, index past the end, or the text has changed under
    /// the caller. Refusing is the point: the alternative is editing a line the
    /// person never saw.
    public static func locate(_ target: Target, in markdown: String) -> Location? {
        let wanted = RecapDigest.foldTitle(target.section)
        let all = locations(in: markdown)
        guard let ordinal = all.first(where: { RecapDigest.foldTitle($0.section) == wanted })?.sectionOrdinal
        else { return nil }
        guard let found = all.first(where: { $0.sectionOrdinal == ordinal && $0.index == target.index })
        else { return nil }
        return found.text == target.text ? found : nil
    }

    // MARK: - Edits

    /// The document with this item's body replaced. `nil` when the target does
    /// not resolve, or when the new body is empty or spans lines — deleting an
    /// item is `removing`, and a two-line item is not something a chip or a
    /// checkbox can produce.
    ///
    /// Continuation lines of the old item go with it: the item was one item to
    /// the reader, and it stays one line to the file.
    public static func replacing(_ target: Target, in markdown: String, with body: String) -> String? {
        guard let found = locate(target, in: markdown), found.contiguous else { return nil }
        guard !body.contains("\n") else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var lines = markdown.components(separatedBy: "\n")
        // Возврат каретки — часть строки, а не разделитель: файл, пришедший с
        // CRLF, не должен получить одну строку из двадцати с другим окончанием.
        let carriage = lines[found.lines.upperBound].hasSuffix("\r") ? "\r" : ""
        lines.replaceSubrange(found.lines, with: [found.indent + found.marker + trimmed + carriage])
        return lines.joined(separator: "\n")
    }

    /// The document with one more item at the end of a section.
    ///
    /// `nil` when the section is not there. Creating the section instead would
    /// be a bigger promise than «Добавить…» makes: where a missing `## Задачи`
    /// belongs in a document, and whether it belongs at all, is a question about
    /// the recap's shape, and this module only moves lines.
    ///
    /// The new line copies the **indent and marker of the section's last item**,
    /// so a document written with `*` keeps its `*` and a nested list does not
    /// suddenly grow a top-level entry. An empty section — heading present, no
    /// bullets — gets the plain `- `.
    public static func appending(
        _ body: String, toSection section: String, in markdown: String
    ) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !body.contains("\n") else { return nil }

        let wanted = RecapDigest.foldTitle(section)
        var lines = markdown.components(separatedBy: "\n")

        // Первая секция с таким именем — та же, на которую смотрит
        // `RecapDigest.section(named:)`; порядковый номер берётся один раз.
        let all = locations(in: markdown)
        if let ordinal = all.first(where: { RecapDigest.foldTitle($0.section) == wanted })?.sectionOrdinal,
           let last = all.last(where: { $0.sectionOrdinal == ordinal }) {
            lines.insert(last.indent + last.marker + trimmed, at: last.lines.upperBound + 1)
            return lines.joined(separator: "\n")
        }

        // Секция есть, но пуста — встаём сразу под её заголовок.
        guard let heading = lines.firstIndex(where: {
            RecapDigest.headingTitle($0.trimmingCharacters(in: .whitespacesAndNewlines))
                .map { RecapDigest.foldTitle($0) == wanted } ?? false
        }) else { return nil }
        lines.insert("- " + trimmed, at: heading + 1)
        return lines.joined(separator: "\n")
    }

    /// The document without this item. Only the item's own lines go; a blank
    /// line that happened to follow it belonged to the document, not to it.
    public static func removing(_ target: Target, from markdown: String) -> String? {
        guard let found = locate(target, in: markdown), found.contiguous else { return nil }
        var lines = markdown.components(separatedBy: "\n")
        lines.removeSubrange(found.lines)
        return lines.joined(separator: "\n")
    }

    // MARK: -

    private static func marker(of trimmedLine: String) -> String {
        for marker in ["- ", "* ", "• "] where trimmedLine.hasPrefix(marker) { return marker }
        return "- "
    }
}
