import Foundation

/// # Конспект, разобранный на секции
///
/// Рекап пишется по фиксированной схеме — `## Итог` / `Решения` / `Задачи` /
/// `Открытые вопросы` / `Ход обсуждения` (`RecapService`, `RecapAssembly`), — и
/// это готовый структурированный слой: `find_decisions` и `find_open_questions`
/// возможны только потому, что он есть.
///
/// **Разбор нарочно терпимый.** На живом архиве (106 конспектов, замер
/// 2026-08-15) заголовки приезжают и с хвостовым пробелом (`## Итог  `), и
/// болдом (`## **Открытые вопросы**`), потому что часть текста написала модель,
/// а не наш сборщик. Строгий разбор молча вернул бы «решений нет» на встрече,
/// где их пять, — а «нет» и «не разобрали» с той стороны разговора выглядят
/// одинаково.
///
/// Секции, которых в документе нет, не выдумываются: пустая секция и
/// отсутствующая — разные ответы.
public struct RecapDigest: Equatable, Sendable {

    public struct Section: Equatable, Sendable {
        /// Заголовок, как он написан в документе (без болда и хвостов).
        public let title: String
        /// Пункты списка. Строка-продолжение приклеена к своему пункту.
        public let items: [String]
        /// Абзацы без маркера — «Итог» состоит только из них.
        public let prose: [String]

        public init(title: String, items: [String], prose: [String]) {
            self.title = title
            self.items = items
            self.prose = prose
        }

        public var isEmpty: Bool { items.isEmpty && prose.isEmpty }

        /// Секция, собранная обратно в текст — то, что уезжает в разговор.
        public var text: String {
            (prose + items.map { "- \($0)" }).joined(separator: "\n")
        }
    }

    public let sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }

    // MARK: - Известные секции

    public static let summaryTitle = "Итог"
    public static let decisionsTitle = "Решения"
    public static let tasksTitle = "Задачи"
    public static let openQuestionsTitle = "Открытые вопросы"
    public static let narrativeTitle = RecapAssembly.narrative
    public static let notesTitle = "Заметки"

    public func section(named title: String) -> Section? {
        let wanted = Self.foldTitle(title)
        return sections.first { Self.foldTitle($0.title) == wanted }
    }

    public var summary: [String] {
        guard let section = section(named: Self.summaryTitle) else { return [] }
        return section.prose + section.items
    }

    public var decisions: [String] { section(named: Self.decisionsTitle)?.items ?? [] }
    public var tasks: [String] { section(named: Self.tasksTitle)?.items ?? [] }
    public var openQuestions: [String] { section(named: Self.openQuestionsTitle)?.items ?? [] }

    // MARK: - Разбор

    public static func parse(_ markdown: String) -> RecapDigest {
        var sections: [Section] = []
        var title: String?
        var items: [String] = []
        var prose: [String] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            paragraph.removeAll()
            guard !joined.isEmpty else { return }
            prose.append(joined)
        }

        func flushSection() {
            flushParagraph()
            defer {
                items.removeAll()
                prose.removeAll()
            }
            // Всё, что стоит до первого `##`, — заголовок документа и его
            // окрестности. Секцией это не является и в ответ не едет.
            guard let title else { return }
            sections.append(Section(title: title, items: items, prose: prose))
        }

        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)

            if let heading = headingTitle(line) {
                flushSection()
                title = heading
                continue
            }
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if let bullet = bulletBody(line) {
                flushParagraph()
                items.append(bullet)
                continue
            }
            // Строка без маркера сразу после пункта — его продолжение, а не
            // новый абзац: модель переносит длинный пункт руками.
            if !items.isEmpty, paragraph.isEmpty {
                items[items.count - 1] += " " + line
                continue
            }
            paragraph.append(line)
        }
        flushSection()

        return RecapDigest(sections: sections)
    }

    /// Заголовок секции, если строка им является. Уровень — ровно `##`: `#` —
    /// это имя документа («Запись 14.08.2026 — рекап»), и секцией оно не будет.
    static func headingTitle(_ line: String) -> String? {
        guard line.hasPrefix("##"), !line.hasPrefix("####") else { return nil }
        var body = line.drop(while: { $0 == "#" })
        while body.first == " " { body = body.dropFirst() }
        var text = String(body)
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(":") { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
        return text.isEmpty ? nil : text
    }

    static func bulletBody(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            let body = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
        }
        return nil
    }

    static func foldTitle(_ title: String) -> String {
        ArchiveSearch.fold(title.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Таймкод

    private static let bracketed = try! NSRegularExpression(
        pattern: #"\[(\d{1,2}:\d{2}(?::\d{2})?)\]"#
    )
    private static let leading = try! NSRegularExpression(
        pattern: #"^\(?(\d{1,2}:\d{2}(?::\d{2})?)\)?\s*[—–-]?"#
    )

    /// Таймкод пункта — или nil, и это чаще всего правильный ответ.
    ///
    /// Берём только две формы: в скобках (`[12:30]`, как их пишет «Ход
    /// обсуждения») и в начале строки (`14:20 — проверить…`, как их пишут
    /// заметки). Любое `15:00` в середине предложения — это время встречи, о
    /// которой договорились, а не место в записи; выдать его как таймкод
    /// значило бы отправить читателя не туда с уверенным видом.
    public static func timecode(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        if let match = bracketed.firstMatch(in: text, range: range),
           let found = Range(match.range(at: 1), in: text) {
            return String(text[found])
        }
        if let match = leading.firstMatch(in: text, range: range),
           let found = Range(match.range(at: 1), in: text) {
            return String(text[found])
        }
        return nil
    }

    /// Секунда, на которую указывает таймкод. `ММ:СС` или `ЧЧ:ММ:СС`.
    public static func seconds(fromTimecode code: String) -> Double? {
        let parts = code.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let numbers = parts.compactMap(Double.init)
        guard numbers.count == parts.count else { return nil }
        if numbers.count == 2 { return numbers[0] * 60 + numbers[1] }
        return numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
    }
}
