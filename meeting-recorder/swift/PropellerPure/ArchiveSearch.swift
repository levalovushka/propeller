import Foundation

/// # Поиск по архиву
///
/// Жил во вьюхе и стоил дорого именно этим. `SearchPalette.matchedRecordings`
/// была вычисляемым свойством, а спрашивали её за один проход `body` шесть-семь
/// раз: по разу на каждый из трёх чипов фильтра (`count(for:)`), потом `items`,
/// потом `groupedItems` через него, потом дважды `items.count`. Внутри каждого
/// вызова — чтение файла конспекта **с диска** на каждую встречу. На архиве из 29
/// встреч это около двухсот файловых чтений на одно нажатие клавиши, и столько же
/// на любое изменение `AppState`, которого во время записи двадцать в секунду.
///
/// Поэтому здесь только арифметика: ни файлов, ни `AttributedString`. Документы
/// собирает вызывающий — один раз, — а подсветку рисует вьюха, потому что шрифты
/// и цвета живут там (`Snippet` отдаёт три куска текста, а не готовую строку).
public struct ArchiveSearch {

    /// Одна встреча в том виде, в каком по ней ищут. Тексты уже прочитаны:
    /// решение «когда читать диск» принимает вызывающий, а не поиск.
    ///
    /// Тексты приводятся к сравнимому виду **один раз, здесь** — и это главная
    /// причина, по которой поиск перестал быть дорогим. Сравнение с
    /// `.caseInsensitive, .diacriticInsensitive` каждый раз заново разбирает
    /// юникод, и на архиве из 29 встреч (700 тысяч знаков) один поиск стоил
    /// **114 мс**, а запрос, которого в архиве нет, — 235 мс. Та же работа по
    /// заранее приведённым строкам — доли миллисекунды.
    ///
    /// Оригиналы остаются рядом: по ним строится кусок текста для показа, и
    /// только для тех встреч, которые попали в ответ.
    public struct Document: Equatable, Sendable {
        public let id: String
        public let title: String
        /// Дата в том виде, в каком её видит человек, — по ней тоже ищут.
        public let dateLabel: String
        /// Транскрипт, заметки, конспект — всё, где ищется текст.
        public let bodies: [String]

        let foldedTitle: [UInt8]
        let foldedDate: [UInt8]
        let foldedBodies: [[UInt8]]

        public init(id: String, title: String, dateLabel: String, bodies: [String]) {
            self.id = id
            self.title = title
            self.dateLabel = dateLabel
            self.bodies = bodies
            self.foldedTitle = ArchiveSearch.foldedBytes(title)
            self.foldedDate = ArchiveSearch.foldedBytes(dateLabel)
            self.foldedBodies = bodies.map(ArchiveSearch.foldedBytes)
        }
    }

    /// Приведение к сравнимому виду: нижний регистр и `ё` → `е`.
    ///
    /// Именно то, что делали флаги сравнения, но однажды на текст, а не заново на
    /// каждое сопоставление. `ё` разворачивается вручную, потому что это и есть
    /// вся «диакритика», которая встречается в русской расшифровке, а полное
    /// снятие диакритики (`folding`) стоит дороже и меняет длину строки.
    static func fold(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    /// То же, но байтами UTF-8.
    ///
    /// Сравнение строк в Swift идёт по графемам — оно правильное и для мегабайта
    /// расшифровок медленное: даже без флагов сравнения один поиск по архиву стоил
    /// 24 мс, то есть больше кадра на каждое нажатие клавиши. Искать подстроку в
    /// UTF-8 можно побайтово: кодировка самосинхронизирующаяся, поэтому байтовое
    /// совпадение — это всегда совпадение символов, а не случайная середина
    /// последовательности.
    static func foldedBytes(_ text: String) -> [UInt8] {
        Array(fold(text).utf8)
    }

    /// Кусок текста вокруг найденного, разложенный на три части: середину вьюха
    /// подсвечивает, края рисует обычным.
    public struct Snippet: Equatable, Sendable {
        public let prefix: String
        public let match: String
        public let suffix: String
    }

    public struct Hit: Equatable, Sendable {
        public let id: String
        /// Сколько раз запрос встретился в текстах. Ноль — значит нашли по
        /// заголовку или дате.
        public let matchCount: Int
        /// Нашлось ли в текстах, а не только в заголовке. По этому признаку
        /// фильтр «Транскрипты» отбирает строки.
        public let inText: Bool
        public let snippet: Snippet?
    }

    /// Сколько встреч показать, когда запроса ещё нет.
    public static let recentCount = 8

    /// Регистр и диакритика не считаются различием: человек, ищущий «ещё»,
    /// должен найти «еще».
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Сколько знаков контекста показать вокруг найденного.
    static let snippetContext = 50

    public init() {}

    /// Пустой запрос — последние встречи, порядок как пришёл.
    public static func run(query: String, over documents: [Document]) -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return documents.prefix(recentCount).map {
                Hit(id: $0.id, matchCount: 0, inText: false, snippet: nil)
            }
        }
        let needle = foldedBytes(trimmed)

        return documents.compactMap { document in
            let inTitle = occurrences(of: needle, in: document.foldedTitle) > 0
                || occurrences(of: needle, in: document.foldedDate) > 0

            var count = 0
            var snippetSource: String?
            for (index, body) in document.foldedBodies.enumerated() {
                let found = occurrences(of: needle, in: body)
                count += found
                if found > 0, snippetSource == nil { snippetSource = document.bodies[index] }
            }

            guard inTitle || count > 0 else { return nil }
            // Кусок для показа строится по оригиналу и только для встреч,
            // попавших в ответ: одно сопоставление на найденное вместо прохода по
            // всему архиву.
            let snippet = snippetSource.flatMap { self.snippet(around: trimmed, in: $0) }
            return Hit(id: document.id, matchCount: count, inText: count > 0, snippet: snippet)
        }
    }

    /// Число вхождений в **уже приведённых** байтах.
    ///
    /// `memmem` вместо своего цикла: она в libc, векторизована, и разница на
    /// мегабайте расшифровок — это разница между «поиск не чувствуется» и
    /// «палитра думает».
    static func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        var count = 0
        haystack.withUnsafeBytes { hay in
            needle.withUnsafeBytes { pin in
                var offset = 0
                while hay.count - offset >= pin.count,
                      let found = memmem(
                          hay.baseAddress! + offset, hay.count - offset,
                          pin.baseAddress!, pin.count
                      ) {
                    count += 1
                    let foundOffset = UnsafeRawPointer(found) - hay.baseAddress!
                    offset = foundOffset + pin.count
                }
            }
        }
        return count
    }

    /// Кусок вокруг первого совпадения, расширенный до границ слов, чтобы строка
    /// не начиналась с половины слова.
    static func snippet(around needle: String, in haystack: String) -> Snippet? {
        guard let found = haystack.range(of: needle, options: options) else { return nil }

        var start = haystack.index(
            found.lowerBound, offsetBy: -snippetContext, limitedBy: haystack.startIndex
        ) ?? haystack.startIndex
        var end = haystack.index(
            found.upperBound, offsetBy: snippetContext, limitedBy: haystack.endIndex
        ) ?? haystack.endIndex
        while start > haystack.startIndex, !haystack[haystack.index(before: start)].isWhitespace {
            start = haystack.index(before: start)
        }
        while end < haystack.endIndex, !haystack[end].isWhitespace {
            end = haystack.index(after: end)
        }

        func clean(_ text: Substring) -> String {
            text.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }

        let leading = (start > haystack.startIndex ? "…" : "") + clean(haystack[start..<found.lowerBound])
        let trailing = clean(haystack[found.upperBound..<end]) + (end < haystack.endIndex ? "…" : "")
        return Snippet(
            prefix: leading.isEmpty ? "" : leading + " ",
            match: String(haystack[found]),
            suffix: trailing.isEmpty ? "" : " " + trailing
        )
    }
}
