import Foundation

/// # Стереть человека
///
/// У человека в этой модели данных нет объекта — есть имя, лежащее текстом в
/// девяти местах: метки спикеров в расшифровке (`[Иван] [12:34]`), поле
/// `speaker` в сегментах (`mergedSegmentsJSON`, `liveSegmentsJSON`), сказанное
/// вслух имя в чекпоинте ASR (`rawSegmentsJSON`), проза конспекта, заголовок
/// встречи, темы, заметки, приглашённые и организатор из календаря
/// (`CalendarMeta`) — и **имя файла**, потому что slug собирается из заголовка и
/// кириллицу не выбрасывает.
///
/// ## Что значит «стереть»
///
/// Реплики остаются, уходит **личность**: ни одного упоминания имени и ни одной
/// атрибуции на него. Так сформулирована цель D роадмапа — «включая упоминания в
/// саммари и атрибуцию реплик», — и так единственно возможно: удалить реплики
/// человека значит выкинуть половину чужой встречи, к которой у него прав нет.
/// Замена — нейтральная метка (`Участник`), а не пропуск: пропуск сделал бы
/// расшифровку нечитаемой, а `[] [12:34]` — сломанной.
///
/// ## Чего это не умеет — вслух
///
/// - **Двое стёртых становятся одним.** Оба получают одну метку, и различить их
///   в расшифровке потом нечем. Обратной операции у стирания нет по определению.
/// - **Словоформа ловится основой плюс окончанием, а не словарём.** «Ивану»,
///   «Иваном», «Алёны», «Марией» — да; «Ваня» от «Ивана» — нет, это другое
///   слово. Список имён, которые считать одним человеком, — вход операции, а не
///   догадка кода.
/// - **Окончание не восстанавливается.** «с Иваном» становится «с Участник», а
///   не «с Участником»: чтобы согласовать замену, надо знать падеж, а знать его
///   значит разбирать язык. Имя ушло — это главное; проза осела.
/// - **Перестраховка сильнее пропуска.** Имя из одной части стирается и само по
///   себе, а основа «Мари» накроет и «Марину». Для необратимой операции
///   приватности это верная сторона ошибки, и она названа здесь, а не выяснится
///   на живом архиве.
public struct PersonName: Equatable, Sendable {
    /// Основы, которые ищутся в тексте, от длинной к короткой: сначала «Иван
    /// Петров», потом «Петров», потом «Иван». Порядок — не украшение: короткая
    /// форма, применённая первой, оставила бы «Участник Петров».
    public let stems: [String]

    /// Сколько букв после основы считаются окончанием, а не другим словом.
    ///
    /// Два, и это замер по языку, а не вкус: русские падежные окончания имён
    /// длиннее двух букв не бывают («Иваном», «Алёной», «Марией»). На трёх
    /// «Петровско-Разумовская» становится станцией метро имени участника —
    /// поймано тестом.
    public static let maxInflectionTail = 2

    /// Часть имени короче этого не стирается сама по себе: «Ян» как отдельное
    /// слово встречается в тексте по другим поводам.
    public static let minStandaloneForm = 3

    /// Хвост, который у имени меняется, а не дописывается: «Алёна» → «Алёны»,
    /// «Мария» → «Марией». Основа получается снятием одной такой буквы — иначе
    /// женские имена не ловятся вовсе, потому что окончание у них не добавляется.
    private static let mutableEndings: Set<Character> = ["а", "я", "ь", "й", "о", "е"]

    /// Ниже этой длины основа не укорачивается: «Лена» → «Лен» — это уже почти
    /// любое слово, и стирание одного человека начало бы задевать текст.
    private static let minStemLength = 4

    public init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.count >= Self.minStandaloneForm }
        var seen = Set<String>()
        var out: [String] = []
        for form in ([trimmed] + parts) where !form.isEmpty {
            let stem = Self.stem(of: form)
            let key = stem.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(stem)
        }
        // Длинные раньше коротких, чтобы полное имя выигрывало у своей части.
        stems = out.sorted { $0.count > $1.count }
    }

    static func stem(of form: String) -> String {
        guard let last = form.last, mutableEndings.contains(Character(last.lowercased())) else {
            return form
        }
        let shortened = String(form.dropLast())
        return shortened.count >= minStemLength ? shortened : form
    }

    public var isEmpty: Bool { stems.isEmpty }
}

public enum PersonErasure {

    /// Ключи, чьё значение не текст про человека, а идентификатор: имя в них
    /// оказаться не может, а замена сломала бы архив.
    ///
    /// Список **разрешает исключения, а не стирание**: любое новое поле по
    /// умолчанию чистится. Обратный порядок («чистим перечисленное») — это ровно
    /// та конструкция, из-за которой атомы завтра остались бы с именами.
    public static let structuralKeys: Set<String> = [
        "id", "filename", "status", "date", "language",
        "eventID", "seriesID", "conferenceURL", "start", "end", "at",
        "phase", "kind", "createdAt", "nextAttemptAt", "terminalReason",
        // Метки проектов на встрече — массив id, а не текст. Имя проекта в
        // `projects.json` при этом чистится как обычная строка, и это верно:
        // «1×1 с Даней» после «стереть Даню» обязан стать «1×1 с Участник».
        "projects",
    ]

    public static let defaultReplacement = "Участник"

    // MARK: - Текст

    /// Есть ли в тексте это имя — в любой из своих форм.
    ///
    /// Тем же поиском, которым стирает `redacted`. Иначе проверка «имени больше
    /// нет» отвечала бы про другое правило, чем стирание, — и однажды разошлась
    /// бы с ним.
    public static func contains(_ text: String, name: PersonName) -> Bool {
        guard !name.isEmpty, !text.isEmpty else { return false }
        // Только свёрнутая копия, без исходной: свёртка не меняет ни букву на
        // не-букву, ни наоборот, поэтому границу слова видно и по ней. Вторая
        // копия шестимегабайтной трассы стоила бы 100 МБ памяти ни за что.
        var folder = Folder()
        let folded = folder.map(text)
        let needles = name.stems.map { folder.map($0) }
        for i in folded.indices {
            guard isWordChar(folded[i]), i == 0 || !isWordChar(folded[i - 1]) else { continue }
            if matchLength(at: i, folded: folded, needles: needles) != nil { return true }
        }
        return false
    }

    /// Текст без имени.
    public static func redacted(
        _ text: String, name: PersonName, with replacement: String = defaultReplacement
    ) -> String {
        guard !name.isEmpty, !text.isEmpty else { return text }
        let chars = Array(text)
        var folder = Folder()
        let folded = folder.map(chars)
        let needles = name.stems.map { folder.map($0) }

        var out = String()
        out.reserveCapacity(text.count)
        var i = 0
        while i < chars.count {
            let atWordStart = isWordChar(chars[i]) && (i == 0 || !isWordChar(chars[i - 1]))
            if atWordStart, let length = matchLength(at: i, folded: folded, needles: needles) {
                out += replacement
                i += length
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// Сколько символов занимает имя, начинающееся в позиции `i`, вместе с
    /// падежным окончанием. Nil — здесь имени нет.
    private static func matchLength(
        at i: Int, folded: [Character], needles: [[Character]]
    ) -> Int? {
        for needle in needles {
            guard i + needle.count <= folded.count else { continue }
            guard Array(folded[i ..< i + needle.count]) == needle else { continue }
            var end = i + needle.count
            var tail = 0
            while end < folded.count, folded[end].isLetter, tail < PersonName.maxInflectionTail {
                end += 1
                tail += 1
            }
            // За окончанием обязана кончиться словоформа. Иначе это не «Иваном»,
            // а другое слово, начинающееся так же.
            if end < folded.count, isWordChar(folded[end]) { continue }
            return end - i
        }
        return nil
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// Регистр и диакритика снимаются **посимвольно**, чтобы индексы совпадали с
    /// исходной строкой: свернуть строку целиком значит потерять соответствие
    /// позиций там, где длина изменилась. Заодно «ё» становится «е» — «Алёна» и
    /// «Алена» один человек.
    ///
    /// Свёртка помнит, что уже считала. Правило от этого не меняется ни на
    /// символ — меняется цена: `folding(options:)` вместе с оборачиванием
    /// символа в строку стоит аллокации на каждый символ, а с приходом трасс
    /// окна звонилки (52 МБ против 4,9 МБ всей папки `meetings/`) стирание
    /// одного человека перевалило за две минуты — замер 2026-08-31 на живом
    /// архиве. Алфавит у любого текста — сотни символов, а платили за них
    /// десятки миллионов раз.
    ///
    /// Память у свёртки локальная, не статическая: глобальное мутабельное
    /// состояние в чистом слое не `Sendable`, и экономия на аллокации не стоит
    /// гонки.
    struct Folder {
        private var cache: [Character: Character] = [:]

        mutating func callAsFunction(_ c: Character) -> Character {
            // ASCII: диакритики в нём нет, а регистр снимается битом — ни
            // словаря, ни аллокации, и это большая часть любого JSON.
            if let ascii = c.asciiValue {
                let lowered = (ascii >= 65 && ascii <= 90) ? ascii + 32 : ascii
                return Character(UnicodeScalar(lowered))
            }
            if let known = cache[c] { return known }
            let s = String(c).folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: nil
            )
            let folded = (s.count == 1 ? s.first : nil) ?? String(c).lowercased().first ?? c
            cache[c] = folded
            return folded
        }

        mutating func map(_ text: String) -> [Character] { map(Array(text)) }

        mutating func map(_ chars: [Character]) -> [Character] {
            var out = [Character]()
            out.reserveCapacity(chars.count)
            for c in chars { out.append(self(c)) }
            return out
        }
    }

    // MARK: - Якорь владельца

    /// Якорь «какая плитка в звонилке моя» после стирания человека.
    ///
    /// Не `redacted`, и это не мелочь: замена превратила бы якорь в «Участник»
    /// — имя, которое после стирания носит **каждый** стёртый, — и следующая
    /// же встреча объявила бы владельцем чужую плитку, а `MeetingRoster`
    /// схлопнул бы этого человека в ряд владельца по всему архиву. Якорь не
    /// проза, а опознание, и исходов у него ровно два: тот же самый или его
    /// нет.
    ///
    /// Правило живёт здесь, а применяется снаружи: значение лежит в
    /// `UserDefaults` (`Preferences.ownerZoomName`), куда чистому слою хода
    /// нет. Из-за этого стирание его и не задевало — единственное место
    /// архива, до которого `ArchivePersonEraser` не дотягивается.
    public static func clearedAnchor(_ anchor: String?, name: PersonName) -> String? {
        guard let anchor, !anchor.isEmpty else { return nil }
        return contains(anchor, name: name) ? nil : anchor
    }

    // MARK: - Имя файла

    /// Имя файла без имени человека. Slug собирается из заголовка встречи и
    /// кириллицу не выбрасывает, поэтому «1:1 с Иваном» доезжает до диска как
    /// `<id>-1-1-s-иваном.md` — файл, который видно в Finder и в Obsidian.
    public static func redactedFilename(
        _ filename: String, name: PersonName, with replacement: String = defaultReplacement
    ) -> String {
        let slugSafe = replacement
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return redacted(filename, name: name, with: slugSafe)
    }

    // MARK: - JSON

    /// Любое значение из индекса без имени человека.
    ///
    /// Обход общий, а не по списку полей: строка чистится по факту того, что она
    /// строка. Поэтому поле, добавленное в `RecordingEntry` после этого кода —
    /// атом, ссылка на проект, что угодно, — чистится само, без правки здесь.
    /// Исключения перечислены (`structuralKeys`) и означают «это идентификатор».
    public static func redactedJSON(
        _ value: Any, name: PersonName, with replacement: String = defaultReplacement
    ) -> Any {
        switch value {
        case let text as String:
            return redacted(text, name: name, with: replacement)
        case let dict as [String: Any]:
            var out = dict
            for (key, item) in dict {
                guard !structuralKeys.contains(key) else { continue }
                out[key] = redactedJSON(item, name: name, with: replacement)
            }
            return out
        case let array as [Any]:
            return array.map { redactedJSON($0, name: name, with: replacement) }
        default:
            return value
        }
    }
}
