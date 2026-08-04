import Foundation

/// # Turning a recap into something the pane can draw
///
/// `RecapService` writes markdown — `## Итог`, then sections of bullets, some of
/// them with a bold lead-in. The pane draws a lead sentence at 18 pt, a
/// paragraph under it, then sections. This is the map between the two, and it is
/// here rather than in the view because markdown from a language model is
/// exactly the kind of input that arrives slightly wrong.
///
/// It already does. The prompt asks for `##` on every heading and 19 of 21
/// recaps on this machine comply; two lost the hashes on the first four
/// headings and kept them lower down. A parser that trusts `##` renders those
/// two as one long wall of text — which is why a bare line followed by bullets
/// counts as a heading too.
public enum RecapPresentation {

    // MARK: - Model

    public struct Summary: Equatable, Sendable {
        /// The one-sentence answer, drawn large.
        public let lead: String
        /// The rest of «Итог».
        public let body: String
        public let sections: [Section]

        public init(lead: String, body: String, sections: [Section]) {
            self.lead = lead
            self.body = body
            self.sections = sections
        }

        public var isEmpty: Bool { lead.isEmpty && body.isEmpty && sections.isEmpty }
    }

    public struct Section: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let blocks: [Block]

        public init(id: String, title: String, blocks: [Block]) {
            self.id = id
            self.title = title
            self.blocks = blocks
        }
    }

    /// A section is not only bullets. «Ход обсуждения» is prose, and rendering
    /// prose as bullets puts a disc in front of every paragraph.
    public enum Block: Equatable, Sendable, Identifiable {
        case bullet(id: String, lead: String?, text: String)
        case paragraph(id: String, text: String)

        public var id: String {
            switch self {
            case .bullet(let id, _, _), .paragraph(let id, _): return id
            }
        }
    }

    // MARK: - Parsing

    /// The heading that becomes the lead. Everything before any heading counts
    /// too, for a recap that opens straight into prose.
    private static let leadHeadings: Set<String> = ["итог", "итоги", "summary"]

    /// The headings `RecapService` actually asks the model for.
    ///
    /// A drifted recap loses its `##` but keeps these words, and «Итог» is
    /// followed by a *paragraph* rather than a bullet — so "next line is a
    /// bullet" alone does not rescue it. Recognising the vocabulary the prompt
    /// itself defines is not guesswork.
    private static let knownHeadings: Set<String> = [
        "итог", "итоги", "решения", "задачи", "открытые вопросы",
        "ход обсуждения", "прочее", "заметки", "summary",
    ]

    public static func summary(fromMarkdown markdown: String) -> Summary {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var sections: [(title: String, lines: [String])] = [(title: "", lines: [])]

        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let title = headingTitle(line, followedBy: lines, at: index) {
                sections.append((title: title, lines: []))
            } else {
                sections[sections.count - 1].lines.append(line)
            }
        }

        var lead = ""
        var body = ""
        var rendered: [Section] = []

        for (index, section) in sections.enumerated() {
            let paragraphs = self.paragraphs(section.lines)
            let isLead = section.title.isEmpty || leadHeadings.contains(section.title.lowercased())
            if isLead, lead.isEmpty, !paragraphs.isEmpty {
                // First paragraph carries the answer; the rest is the reasoning.
                let rest = paragraphs.dropFirst().map(stripEmphasis).joined(separator: "\n\n")
                let split = splitFirstSentence(stripEmphasis(paragraphs[0]))
                lead = split.first
                body = [split.rest, rest].filter { !$0.isEmpty }.joined(separator: "\n\n")
                continue
            }
            guard !section.title.isEmpty else { continue }
            let blocks = self.blocks(section.lines, sectionIndex: index)
            guard !blocks.isEmpty else { continue }
            rendered.append(Section(id: "s\(index)", title: section.title, blocks: blocks))
        }

        return Summary(lead: lead, body: body, sections: rendered)
    }

    /// A heading is either marked or obvious.
    ///
    /// Marked: `## Что-то`. Obvious: a short line with no sentence punctuation
    /// whose next non-empty line is a bullet — which is what the two drifted
    /// recaps look like, and what no ordinary paragraph looks like.
    static func headingTitle(_ line: String, followedBy lines: [String], at index: Int) -> String? {
        if line.hasPrefix("#") {
            let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        guard !line.isEmpty, line.count <= 40, !line.hasPrefix("- "), !line.hasPrefix("*") else {
            return nil
        }
        guard line.last.map({ !".!?:,;".contains($0) }) ?? false else { return nil }
        // Bold-only line — «**Итог**» — is a heading whatever follows it.
        let bare = stripEmphasis(line)
        if line.hasPrefix("**"), line.hasSuffix("**"), !bare.isEmpty { return bare }
        // A heading the prompt asked for, hashes or not.
        if knownHeadings.contains(bare.lowercased()) { return bare }
        let next = lines.dropFirst(index + 1).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        guard let next = next?.trimmingCharacters(in: .whitespaces), next.hasPrefix("- ") else { return nil }
        return bare
    }

    /// The first sentence, and whatever follows it.
    ///
    /// The comps give the lead one sentence at 18 pt and the reasoning a
    /// paragraph at 14. Real recaps do not oblige: «Итог» came back as a single
    /// paragraph in all twenty-one on the author's machine, between 109 and 586
    /// characters. Setting 586 characters in 18 pt semibold is a wall, so the
    /// paragraph is cut where its first sentence ends — which is the shape the
    /// design asks for, drawn from the text there actually is.
    ///
    /// A sentence that runs past `leadLimit` is left whole rather than chopped
    /// mid-clause: a lead that ends in the middle of a thought is worse than a
    /// long one.
    static func splitFirstSentence(_ text: String, leadLimit: Int = 220) -> (first: String, rest: String) {
        guard text.count > leadLimit else { return (text, "") }
        let terminators: Set<Character> = [".", "!", "?"]
        var index = text.startIndex
        var boundary: String.Index?
        while index < text.endIndex {
            if terminators.contains(text[index]) {
                let after = text.index(after: index)
                // A full stop inside «т.д.» or a decimal is not a boundary.
                if after == text.endIndex || text[after] == " " {
                    boundary = after
                    break
                }
            }
            index = text.index(after: index)
        }
        guard let boundary, boundary < text.endIndex else { return (text, "") }
        let first = String(text[..<boundary]).trimmingCharacters(in: .whitespaces)
        let rest = String(text[boundary...]).trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty, !rest.isEmpty else { return (text, "") }
        return (first, rest)
    }

    /// Blank-line separated paragraphs, bullets excluded.
    static func paragraphs(_ lines: [String]) -> [String] {
        var out: [String] = []
        var current: [String] = []
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty { out.append(current.joined(separator: " ")); current = [] }
            } else if line.hasPrefix("- ") {
                if !current.isEmpty { out.append(current.joined(separator: " ")); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out.filter { !$0.isEmpty }
    }

    static func blocks(_ lines: [String], sectionIndex: Int) -> [Block] {
        var out: [Block] = []
        var prose: [String] = []

        func flushProse() {
            guard !prose.isEmpty else { return }
            let text = prose.joined(separator: " ")
            if !text.isEmpty {
                out.append(.paragraph(id: "s\(sectionIndex)p\(out.count)", text: stripEmphasis(text)))
            }
            prose = []
        }

        for line in lines {
            if line.hasPrefix("- ") {
                flushProse()
                let content = String(line.dropFirst(2))
                let (lead, text) = splitLead(content)
                out.append(.bullet(id: "s\(sectionIndex)b\(out.count)", lead: lead, text: text))
            } else if line.isEmpty {
                flushProse()
            } else {
                prose.append(line)
            }
        }
        flushProse()
        return out
    }

    /// «**Мета как основа навигации:** остальное» → the bold part and the rest.
    ///
    /// The colon stays with the lead, because that is where the comps put it —
    /// and because a bold phrase that ends mid-clause reads as a mistake.
    static func splitLead(_ text: String) -> (lead: String?, rest: String) {
        guard text.hasPrefix("**"), let close = range(ofClosingEmphasisIn: text) else {
            return (nil, stripEmphasis(text))
        }
        var lead = String(text[text.index(text.startIndex, offsetBy: 2)..<close.lowerBound])
        var rest = String(text[close.upperBound...])
        // The colon may sit inside or outside the emphasis; normalise to inside.
        if !lead.hasSuffix(":"), rest.hasPrefix(":") {
            lead += ":"
            rest.removeFirst()
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        lead = lead.trimmingCharacters(in: .whitespaces)
        guard !lead.isEmpty else { return (nil, stripEmphasis(text)) }
        return (lead + " ", stripEmphasis(rest))
    }

    private static func range(ofClosingEmphasisIn text: String) -> Range<String.Index>? {
        let afterOpen = text.index(text.startIndex, offsetBy: 2)
        return text.range(of: "**", range: afterOpen..<text.endIndex)
    }

    /// Remaining `**` and `__` inside body text.
    ///
    /// Not a markdown renderer — the pane draws one bold lead per bullet and
    /// nothing else, so stray emphasis is noise rather than meaning.
    static func stripEmphasis(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
