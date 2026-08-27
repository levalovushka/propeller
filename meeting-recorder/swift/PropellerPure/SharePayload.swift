import Foundation

/// # Что уезжает в ссылку
///
/// Документ, а не готовый HTML. Спека 2026-08-24 предполагала второе, и это
/// отменено 2026-08-27: страница-вьюер одна на все шеры, и пока она рисует
/// разобранный документ, её можно переодеть под новый дизайн, **не переиздавая
/// уже разосланные ссылки**. Готовый HTML запер бы каждую ссылку в той
/// вёрстке, в которой её отправили.
///
/// Уезжает ровно то, что видно в панели встречи: строка атрибутов, имя и
/// саммари. Расшифровки здесь нет и не будет — делится содержание, не наблюдения
/// (`VISION.md` §6).
public struct SharePayload: Encodable, Equatable {

    /// Версия формата. Вьюер отказывается открывать незнакомую, а не рисует
    /// половину: непонятый шер лучше показать честной строкой.
    public let v = 1
    public let title: String
    /// Чипы строки атрибутов — уже собранными строками.
    ///
    /// Не датой и числом: русские сокращения месяцев и «человек / человека»
    /// живут в `MeetingMeta`, и вторая их реализация на JavaScript разошлась бы
    /// с первой на первой же правке. Чип — это лист, у него нет своей логики.
    public let meta: [String]
    public let blocks: [Block]

    public struct Block: Encodable, Equatable {
        public let kind: String
        public let spans: [Span]
    }

    public struct Span: Encodable, Equatable {
        public let text: String
        /// `nil`, а не `false`: невыделенных отрезков в саммари подавляющее
        /// большинство, и `"bold":false` у каждого — это треть веса блоба
        /// на слове, которое ничего не значит.
        public let bold: Bool?
        public let italic: Bool?
    }

    public init(title: String, meta: [String], blocks: [Block]) {
        self.title = title
        self.meta = meta
        self.blocks = blocks
    }

    /// Собирает то, что рисует панель встречи, — из того же, из чего рисует она.
    public static func make(
        title: String,
        date: Date?,
        peopleCount: Int,
        document: SummaryDocument,
        now: Date = Date()
    ) -> SharePayload {
        var meta: [String] = []
        if let date { meta.append(MeetingMeta.when(date, now: now)) }
        if let people = MeetingMeta.people(peopleCount) { meta.append(people) }

        let blocks = document.blocks.compactMap { block -> Block? in
            let spans = block.spans
                .filter { !$0.text.isEmpty }
                .map { Span(text: $0.text, bold: $0.bold ? true : nil, italic: $0.italic ? true : nil) }
            // Пустой блок в файле — это разделительная строка markdown, а не
            // абзац. На экране её нет, и в ссылке ей делать нечего.
            guard !spans.isEmpty else { return nil }
            return Block(kind: block.kind.rawValue, spans: spans)
        }

        return SharePayload(title: title, meta: meta, blocks: blocks)
    }

    /// JSON без пробелов и с отсортированными ключами.
    ///
    /// Сортировка — чтобы одно и то же саммари давало один и тот же байтовый
    /// документ: иначе тест на круг «собрали → сжали → зашифровали → разобрали»
    /// пришлось бы писать через разбор, а не через сравнение.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
