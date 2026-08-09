import Foundation

/// # Саммари как документ, который можно править
///
/// `RecapService` пишет markdown, панель его рисует — а теперь ещё и правит,
/// поэтому модель между ними обязана пережить круг «разобрали → показали →
/// поправили → записали». Это и есть вся разница с прежним разбором на чтение:
/// тот снимал выделение, склеивал абзацы и выбрасывал всё, чего не рисует. Для
/// подписи это нормально, для файла, который сейчас перезапишут, — смертельно.
///
/// # Четыре вида блока
///
/// Ровно те, что в саммари есть: `lead` — предложение-ответ 20/26, `heading` —
/// заголовок раздела 14/22 bold, `body` — абзац, `bullet` — пункт списка. Из
/// этих же четырёх собран выпадающий список в панели действий, поэтому названия
/// живут здесь, а не по вызовам: копирайт — в одном месте.
///
/// # Почему разбор терпит кривой markdown
///
/// Промпт просит `##` у каждого заголовка, и 19 конспектов из 21 на машине
/// автора слушаются; два потеряли решётки на первых четырёх и сохранили ниже.
/// Разбор, который верит `##`, рисует такой конспект стеной текста — поэтому
/// голая строка перед списком тоже считается заголовком.
public struct SummaryDocument: Equatable, Sendable {

    // MARK: - Модель

    public struct Span: Equatable, Sendable {
        public var text: String
        public var bold: Bool
        public var italic: Bool

        public init(_ text: String, bold: Bool = false, italic: Bool = false) {
            self.text = text
            self.bold = bold
            self.italic = italic
        }
    }

    public struct Block: Equatable, Sendable, Identifiable {
        public enum Kind: String, Equatable, Sendable, CaseIterable {
            /// Предложение-ответ, 20/26 semibold. Первый абзац «Итога».
            case lead
            /// Заголовок раздела, 14/22 bold.
            case heading
            /// Обычный абзац, 14/22.
            case body
            /// Пункт списка — тот же абзац с диском и втяжкой.
            case bullet

            /// Как этот вид называется в выпадающем списке панели действий.
            ///
            /// «Заголовок» — не `heading`: в колонке саммари самый крупный
            /// текст — это `lead`, и человек, выбирающий «заголовок», хочет
            /// именно его. Раздел внутри саммари — «подзаголовок», по размеру и
            /// по смыслу.
            public var title: String {
                switch self {
                case .lead:    return "Заголовок"
                case .heading: return "Подзаголовок"
                case .body:    return "Обычный"
                case .bullet:  return "Список"
                }
            }
        }

        public var id: String
        public var kind: Kind
        public var spans: [Span]

        public init(id: String, kind: Kind, spans: [Span]) {
            self.id = id
            self.kind = kind
            self.spans = spans
        }

        public init(id: String, kind: Kind, text: String) {
            self.init(id: id, kind: kind, spans: text.isEmpty ? [] : [Span(text)])
        }

        /// Текст без разметки — то, что видно на экране.
        public var text: String { spans.map(\.text).joined() }
    }

    public var blocks: [Block]

    /// Всё, что разбор снял с начала файла и обязан вернуть дословно: YAML-шапка
    /// формата «Obsidian» и строка `## Итог` — в этом порядке, через пустую строку.
    ///
    /// Панель их не рисует — вся колонка и есть саммари, повторять незачем. Но
    /// файл читают и другие: Obsidian, экспорт, следующий проход модели. Молча
    /// выкинуть заголовок при первом же сохранении — это поправить чужой файл,
    /// не спросив, поэтому он хранится дословно и возвращается на место.
    ///
    /// Шапка едет здесь же, а не отдельным полем, потому что это поле —
    /// единственное, что переживает круг через редактор: `SummaryText.document`
    /// собирает документ заново из текста колонки и переносит ровно `leadHeading`.
    /// Отдельное поле терялось бы на первой же правке — то есть ровно там, где
    /// шапку и теряли.
    public var leadHeading: String?

    public init(blocks: [Block], leadHeading: String? = nil) {
        self.blocks = blocks
        self.leadHeading = leadHeading
    }

    public var isEmpty: Bool {
        blocks.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public static let empty = SummaryDocument(blocks: [])

    // MARK: - Разбор

    /// Заголовок, который становится ведущим абзацем. Текст до любого заголовка
    /// считается тем же — конспект, начинающийся сразу с прозы, это норма.
    private static let leadHeadings: Set<String> = ["итог", "итоги", "summary"]

    /// Заголовки, которые промпт просит у модели.
    ///
    /// У съехавшего конспекта решётки пропали, а слова остались, и за «Итогом»
    /// идёт *абзац*, а не пункт списка — правило «дальше список» его не спасает.
    /// Узнавать словарь, заданный самим промптом, — не гадание.
    private static let knownHeadings: Set<String> = [
        "итог", "итоги", "решения", "задачи", "открытые вопросы",
        "ход обсуждения", "прочее", "заметки", "summary",
    ]

    public static func parse(markdown: String) -> SummaryDocument {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let (frontmatter, rest) = splittingFrontmatter(text)
        let lines = rest
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // Пас 1 — разрезать на разделы по заголовкам.
        var sections: [(title: String?, raw: String?, lines: [String])] = [(nil, nil, [])]
        for (index, line) in lines.enumerated() {
            if let title = headingTitle(line, followedBy: lines, at: index) {
                sections.append((title, line, []))
            } else {
                sections[sections.count - 1].lines.append(line)
            }
        }

        // Пас 2 — разделы в блоки.
        var out: [Block] = []
        var leadHeading: String?
        var leadTaken = false
        var counter = 0
        func nextID() -> String { defer { counter += 1 }; return "b\(counter)" }

        for section in sections {
            let isLeadSection = section.title.map { leadHeadings.contains($0.lowercased()) } ?? true
            var body = blocks(section.lines, nextID: nextID)
            guard !body.isEmpty else { continue }   // заголовок ни над чем не рисуем

            if isLeadSection, !leadTaken {
                leadTaken = true
                leadHeading = section.raw
                if body[0].kind == .body { body = promotingLead(body, nextID: nextID) }
            } else if let title = section.title {
                out.append(Block(id: nextID(), kind: .heading, spans: spans(inline: title)))
            }
            out.append(contentsOf: body)
        }

        return SummaryDocument(blocks: out, leadHeading: kept(frontmatter, leadHeading))
    }

    /// Снять YAML-шапку с начала файла — дословно, ничего в ней не разбирая.
    ///
    /// В формате «Obsidian» `RecapService` пишет над конспектом `---` / `title:`
    /// / `tags:` / `---`, и по этим тегам в vault'е ищут. Разбор про YAML не
    /// знает: `---` заголовком не считается, а две строки под ним склеивались в
    /// один абзац и рисовались лидом — самым крупным текстом колонки. Хуже
    /// того, первое же сохранение писало файл без них.
    ///
    /// Шапка — только с самого начала и только целиком: первая непустая строка
    /// ровно `---` и где-то ниже закрывающая `---`. Иначе это горизонтальная
    /// черта в теле, и трогать её нечем.
    private static func splittingFrontmatter(_ text: String) -> (String?, String) {
        let lines = text.components(separatedBy: "\n")
        func isFence(_ line: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces) == "---"
        }
        guard let open = lines.firstIndex(where: {
                  !$0.trimmingCharacters(in: .whitespaces).isEmpty
              }),
              isFence(lines[open]),
              let close = lines[(open + 1)...].firstIndex(where: isFence)
        else { return (nil, text) }
        return (lines[open...close].joined(separator: "\n"),
                lines[(close + 1)...].joined(separator: "\n"))
    }

    /// Шапка и `## Итог` — одной строкой: обратно их несёт одно поле.
    ///
    /// Пустая строка между ними — тот же разделитель, каким `markdown` разводит
    /// блоки, поэтому файл собирается обратно ровно таким, каким пришёл.
    private static func kept(_ frontmatter: String?, _ leadHeading: String?) -> String? {
        guard let frontmatter else { return leadHeading }
        guard let leadHeading else { return frontmatter }
        return frontmatter + "\n\n" + leadHeading
    }

    /// Первый абзац «Итога» становится ведущим — и, если он единственный и
    /// длинный, режется по концу первого предложения.
    ///
    /// Резать только когда абзац один — это то, что делает круг устойчивым.
    /// Разрезав однажды, мы сохраняем два абзаца; на следующем разборе их уже
    /// два, правило не срабатывает, и лид не съедается по предложению с каждым
    /// сохранением.
    private static func promotingLead(_ blocks: [Block], nextID: () -> String) -> [Block] {
        var blocks = blocks
        let paragraphs = blocks.filter { $0.kind == .body }.count
        blocks[0].kind = .lead
        guard paragraphs == 1 else { return blocks }
        let (head, tail) = splitFirstSentence(blocks[0].spans)
        guard !tail.isEmpty else { return blocks }
        blocks[0].spans = head
        blocks.insert(Block(id: nextID(), kind: .body, spans: tail), at: 1)
        return blocks
    }

    /// Заголовок — либо помеченный, либо очевидный.
    ///
    /// Помеченный: `## Что-то`. Очевидный: короткая строка без знаков конца
    /// предложения, за которой идёт пункт списка — так выглядят два съехавших
    /// конспекта и не выглядит ни один обычный абзац.
    static func headingTitle(_ line: String, followedBy lines: [String], at index: Int) -> String? {
        if line.hasPrefix("#") {
            let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        guard !line.isEmpty, line.count <= headingMaxLength,
              !line.hasPrefix("- "), !line.hasPrefix("*") else { return nil }
        guard line.last.map({ !".!?:,;".contains($0) }) ?? false else { return nil }
        let bare = plain(line)
        // Строка целиком жирная — «**Итог**» — заголовок при любом продолжении.
        if line.hasPrefix("**"), line.hasSuffix("**"), !bare.isEmpty { return bare }
        if knownHeadings.contains(bare.lowercased()) { return bare }
        let next = lines.dropFirst(index + 1).first { !$0.isEmpty }
        guard let next, next.hasPrefix("- ") else { return nil }
        return bare
    }

    /// Длиннее — уже не заголовок, а короткая мысль без точки.
    private static let headingMaxLength = 40

    /// Строки одного раздела в абзацы и пункты.
    static func blocks(_ lines: [String], nextID: () -> String) -> [Block] {
        var out: [Block] = []
        var prose: [String] = []

        func flush() {
            let text = prose.joined(separator: " ")
            prose = []
            guard !text.isEmpty else { return }
            out.append(Block(id: nextID(), kind: .body, spans: spans(inline: text)))
        }

        for line in lines {
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                out.append(Block(id: nextID(), kind: .bullet,
                                 spans: spans(inline: String(line.dropFirst(2)))))
            } else if line.isEmpty || line == "---" {
                flush()
            } else {
                prose.append(line)
            }
        }
        flush()
        return out
    }

    // MARK: - Первое предложение

    /// Первое предложение и всё, что за ним, — по цепочке отрезков, чтобы
    /// жирное слово не потеряло жирность на границе разреза.
    ///
    /// Макет даёт лиду одно предложение в 20 pt, а рассуждению — абзац в 14.
    /// Настоящие конспекты этого не обещают: «Итог» приходил одним абзацем во
    /// всех двадцати одном, от 109 до 586 знаков. 586 знаков в 20 pt semibold —
    /// это стена, поэтому абзац режется там, где кончается первое предложение.
    ///
    /// Предложение длиннее `leadLimit` остаётся целым: лид, оборванный посреди
    /// мысли, хуже длинного.
    static func splitFirstSentence(
        _ spans: [Span], leadLimit: Int = 220
    ) -> (head: [Span], tail: [Span]) {
        let text = spans.map(\.text).joined()
        guard text.count > leadLimit else { return (spans, []) }
        guard let boundary = sentenceBoundary(in: text) else { return (spans, []) }
        let head = trimmed(prefix(of: spans, upTo: boundary))
        let tail = trimmed(suffix(of: spans, from: boundary))
        guard !head.isEmpty, !tail.isEmpty else { return (spans, []) }
        return (head, tail)
    }

    /// Смещение сразу за первой точкой, которая действительно кончает
    /// предложение: точка внутри «т. д.» или в числе границей не считается.
    private static func sentenceBoundary(in text: String) -> Int? {
        let characters = Array(text)
        for (index, character) in characters.enumerated() where ".!?".contains(character) {
            let after = index + 1
            if after == characters.count { return nil }
            if characters[after] == " " { return after }
        }
        return nil
    }

    private static func prefix(of spans: [Span], upTo offset: Int) -> [Span] {
        var out: [Span] = []
        var seen = 0
        for span in spans {
            let length = span.text.count
            if seen + length <= offset {
                out.append(span)
            } else if seen < offset {
                var cut = span
                cut.text = String(span.text.prefix(offset - seen))
                out.append(cut)
            }
            seen += length
        }
        return out
    }

    private static func suffix(of spans: [Span], from offset: Int) -> [Span] {
        var out: [Span] = []
        var seen = 0
        for span in spans {
            let length = span.text.count
            if seen >= offset {
                out.append(span)
            } else if seen + length > offset {
                var cut = span
                cut.text = String(span.text.dropFirst(offset - seen))
                out.append(cut)
            }
            seen += length
        }
        return out
    }

    private static func trimmed(_ spans: [Span]) -> [Span] {
        var out = spans
        while let first = out.first {
            let text = String(first.text.drop(while: { $0 == " " }))
            if text.isEmpty { out.removeFirst() } else { out[0].text = text; break }
        }
        while let last = out.last {
            let text = String(last.text.reversed().drop(while: { $0 == " " }).reversed())
            if text.isEmpty { out.removeLast() } else { out[out.count - 1].text = text; break }
        }
        return out
    }

    // MARK: - Разметка внутри строки

    /// `**жирное**`, `*курсив*`, `***и то и другое***` — и то же самое на `_`.
    ///
    /// Не полный markdown: панель рисует жирное и курсив и больше ничего, а
    /// ссылки и код в конспекте модели не встречаются. Звёздочка, стоящая в
    /// тексте сама по себе, прочитается как разметка и такой же вернётся —
    /// круг замкнётся, вид не изменится.
    static func spans(inline text: String) -> [Span] {
        var out: [Span] = []
        var current = ""
        var bold = false
        var italic = false
        let characters = Array(text)
        var index = 0

        func flush() {
            guard !current.isEmpty else { return }
            out.append(Span(current, bold: bold, italic: italic))
            current = ""
        }

        while index < characters.count {
            let character = characters[index]
            guard character == "*" || character == "_" else {
                current.append(character)
                index += 1
                continue
            }
            let run = markerRun(characters, at: index, of: character)
            // Одиночное подчёркивание внутри слова — часть слова, не курсив.
            if character == "_", run == 1, isInsideWord(characters, at: index) {
                current.append(character)
                index += 1
                continue
            }
            switch run {
            case 1:  flush(); italic.toggle()
            case 2:  flush(); bold.toggle()
            default: flush(); bold.toggle(); italic.toggle()
            }
            index += min(run, 3)
        }
        flush()
        return out.filter { !$0.text.isEmpty }
    }

    private static func markerRun(_ characters: [Character], at index: Int, of marker: Character) -> Int {
        var run = 0
        var cursor = index
        while cursor < characters.count, characters[cursor] == marker, run < 3 {
            run += 1
            cursor += 1
        }
        return run
    }

    private static func isInsideWord(_ characters: [Character], at index: Int) -> Bool {
        let before = index > 0 ? characters[index - 1] : " "
        let after = index + 1 < characters.count ? characters[index + 1] : " "
        return before.isLetter || before.isNumber ? (after.isLetter || after.isNumber) : false
    }

    static func inline(_ spans: [Span]) -> String {
        spans.reduce(into: "") { out, span in
            guard !span.text.isEmpty else { return }
            let marker = (span.bold ? "**" : "") + (span.italic ? "*" : "")
            out += marker + span.text + String(marker.reversed())
        }
    }

    /// Текст без разметки — то же, что `Block.text`, но для сырой строки.
    static func plain(_ text: String) -> String {
        spans(inline: text).map(\.text).joined()
    }

    // MARK: - Обратно в текст

    /// Саммари без разметки — то, что уходит в буфер для Telegram и системного
    /// Copy. Никаких `##` / `**` / `- `: только абзацы и `•` у пунктов. Служебный
    /// «Итог» не включается — это ярлык файла, не часть текста встречи.
    public var plainText: String {
        var out = ""
        var previous: Block.Kind?
        for block in blocks {
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !out.isEmpty {
                out += (previous == .bullet && block.kind == .bullet) ? "\n" : "\n\n"
            }
            out += block.kind == .bullet ? "• " + text : text
            previous = block.kind
        }
        return out
    }

    /// Документ как файл на диске.
    ///
    /// Заголовки всегда получают `##`, пункты — `- `: файл, который мы написали
    /// сами, читается однозначно, даже если тот, что мы прочитали, был съехавшим.
    public var markdown: String {
        var out = ""
        var previous: Block.Kind?
        if let leadHeading, !leadHeading.isEmpty {
            out = leadHeading
            previous = .heading
        }
        for block in blocks {
            let text = SummaryDocument.inline(block.spans)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if !out.isEmpty {
                // Пункты списка идут вплотную — так их пишет `RecapService`, и
                // так они остаются одним списком, а не чередой абзацев с дисками.
                out += (previous == .bullet && block.kind == .bullet) ? "\n" : "\n\n"
            }
            out += line(for: block.kind, text: text)
            previous = block.kind
        }
        return out.isEmpty ? "" : out + "\n"
    }

    private func line(for kind: Block.Kind, text: String) -> String {
        switch kind {
        case .heading: return "## " + text
        case .bullet:  return "- " + text
        case .lead, .body: return text
        }
    }
}
