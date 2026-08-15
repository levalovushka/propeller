import Foundation

/// Встреча в том виде, в каком её отдают Клоду на первом шаге.
///
/// Тексты уже прочитаны: решение «когда идти на диск» принимает сервер, а не
/// правило отбора — по той же причине, по которой это устроено так в
/// `ArchiveSearch`.
public struct MeetingCard: Equatable, Sendable {
    public let id: String
    public let date: Date
    public let title: String
    public let durationSeconds: Double
    public let topics: [String]
    public let tags: [String]
    /// Кто говорил — из размеченной расшифровки. Пусто, если её ещё нет.
    ///
    /// На живом архиве это почти всегда `Speaker N`: имя получает только
    /// владелец микрофона. Поэтому одного этого списка для вопроса «что было со
    /// встреч с Даней» не хватает — см. `invited` и `passesPeople`.
    public let people: [String]
    /// Кого звали — приглашённые и организатор из календарного события.
    /// Настоящие личности встречи и лежат здесь: имена или почты.
    public let invited: [String]
    /// Дата словами — по ней тоже ищут («август», «14.08»).
    public let dateLabel: String
    /// Расшифровка, заметки, конспект — всё, где ищется текст.
    public let bodies: [String]

    public init(
        id: String,
        date: Date,
        title: String,
        durationSeconds: Double,
        topics: [String],
        tags: [String],
        people: [String],
        invited: [String] = [],
        dateLabel: String,
        bodies: [String]
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.durationSeconds = durationSeconds
        self.topics = topics
        self.tags = tags
        self.people = people
        self.invited = invited
        self.dateLabel = dateLabel
        self.bodies = bodies
    }
}

/// # Кого отдать на `search_meetings`, `find_decisions`, `find_open_questions`
///
/// Отбор — арифметика над уже прочитанным, и живёт здесь, потому что «нашлось
/// не то» проверяется тестом, а не разговором с моделью.
public enum MeetingLookup {

    /// Сколько встреч отдавать за раз. Это точка входа, а не ответ: двадцать
    /// строк модель прочитает и выберет, двести — потратит на них контекст,
    /// который нужен ей для самого разговора.
    public static let defaultLimit = 20
    /// Сколько решений или вопросов отдавать за раз.
    public static let harvestLimit = 40

    public struct Filter: Equatable, Sendable {
        public let query: String
        public let from: Date?
        public let to: Date?
        public let people: [String]

        public init(query: String = "", from: Date? = nil, to: Date? = nil, people: [String] = []) {
            self.query = query
            self.from = from
            self.to = to
            self.people = people
        }
    }

    public struct Result: Equatable, Sendable {
        public let card: MeetingCard
        /// Кусок текста вокруг найденного — те самые «две строки». nil, когда
        /// запроса не было или нашлось по заголовку.
        public let snippet: ArchiveSearch.Snippet?

        public init(card: MeetingCard, snippet: ArchiveSearch.Snippet?) {
            self.card = card
            self.snippet = snippet
        }
    }

    /// Порядок — от новых к старым, а не по числу совпадений.
    ///
    /// В разговоре «что там было по проекту» свежая встреча почти всегда нужнее
    /// той, где слово встретилось семь раз полгода назад. Вызывающий отдаёт
    /// карточки уже отсортированными; здесь порядок только сохраняется.
    public static func run(
        cards: [MeetingCard],
        filter: Filter,
        limit: Int = defaultLimit
    ) -> [Result] {
        let narrowed = cards.filter { passesDates($0, filter) && passesPeople($0, filter) }
        let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return narrowed.prefix(limit).map { Result(card: $0, snippet: nil) }
        }

        let documents = narrowed.map {
            ArchiveSearch.Document(
                id: $0.id,
                title: $0.title + " " + $0.topics.joined(separator: " ") + " " + $0.tags.joined(separator: " "),
                dateLabel: $0.dateLabel,
                bodies: $0.bodies
            )
        }
        let hits = ArchiveSearch.run(query: query, over: documents)
        let byID = Dictionary(narrowed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return hits.prefix(limit).compactMap { hit in
            guard let card = byID[hit.id] else { return nil }
            return Result(card: card, snippet: hit.snippet)
        }
    }

    static func passesDates(_ card: MeetingCard, _ filter: Filter) -> Bool {
        if let from = filter.from, card.date < from { return false }
        if let to = filter.to, card.date > to { return false }
        return true
    }

    /// Человек назван — значит он в этой встрече был.
    ///
    /// «Был» приходится собирать из трёх мест, и это не щедрость, а состояние
    /// данных. Диаризация даёт имя одному человеку — владельцу микрофона, —
    /// остальные остаются `Speaker N`; настоящие личности живут в приглашённых
    /// из календаря и в заголовке («1х1 с Даней»). Спросив про Даню и получив
    /// «ничего не нашлось», человек прочитает «такой встречи не было», а она
    /// была — это худший ответ из возможных, и собирать стог из трёх источников
    /// дешевле, чем его давать.
    static func passesPeople(_ card: MeetingCard, _ filter: Filter) -> Bool {
        guard !filter.people.isEmpty else { return true }
        let haystack = Set((card.people + card.invited + [card.title]).flatMap(nameStems))
        return filter.people.contains { asked in
            let wanted = nameStems(asked)
            return !wanted.isEmpty && wanted.contains { haystack.contains($0) }
        }
    }

    /// Слова строки, приведённые к основе.
    ///
    /// Русское имя в заголовке стоит в падеже — «с Даней», — а спрашивают
    /// именительным. Поэтому сравниваются не строки, а основы: с конца слова
    /// снимается не больше двух гласных и мягких знаков, и «даня» с «даней»
    /// сходятся на «дан». Больше двух снимать нельзя — короткие слова начнут
    /// совпадать друг с другом, и фильтр перестанет фильтровать.
    static func nameStems(_ text: String) -> [String] {
        ArchiveSearch.fold(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
            .map(stem)
    }

    private static let endings: Set<Character> = ["а", "е", "и", "о", "у", "ы", "э", "ю", "я", "й", "ь", "ъ"]

    static func stem(_ word: String) -> String {
        var out = word
        var trimmed = 0
        while trimmed < 2, out.count > 2, let last = out.last, endings.contains(last) {
            out.removeLast()
            trimmed += 1
        }
        return out
    }

    // MARK: - Решения и открытые вопросы

    /// Пункт конспекта вместе с тем, откуда он.
    public struct HarvestedItem: Equatable, Sendable {
        public let meetingID: String
        public let meetingTitle: String
        public let date: Date
        public let text: String
        /// Таймкод, если пункт его нёс. Чаще всего nil — см. `RecapDigest.timecode`.
        public let timecode: String?

        public init(meetingID: String, meetingTitle: String, date: Date, text: String, timecode: String?) {
            self.meetingID = meetingID
            self.meetingTitle = meetingTitle
            self.date = date
            self.text = text
            self.timecode = timecode
        }
    }

    /// Собрать одну секцию конспектов по всему архиву.
    ///
    /// `topic` сужает по самому пункту **и** по встрече: спросив «что решили по
    /// найму», человек имеет в виду и решение, где сказано «найм», и решение со
    /// встречи, которая вся про найм.
    public static func harvest(
        section title: String,
        from meetings: [(card: MeetingCard, digest: RecapDigest)],
        topic: String = "",
        limit: Int = harvestLimit
    ) -> [HarvestedItem] {
        let needle = ArchiveSearch.fold(topic.trimmingCharacters(in: .whitespacesAndNewlines))
        var out: [HarvestedItem] = []
        for meeting in meetings {
            guard let section = meeting.digest.section(named: title) else { continue }
            let meetingMatches = needle.isEmpty
                || ArchiveSearch.fold(meeting.card.title).contains(needle)
                || meeting.card.topics.contains { ArchiveSearch.fold($0).contains(needle) }
                || meeting.card.tags.contains { ArchiveSearch.fold($0).contains(needle) }
            for item in section.items {
                guard meetingMatches || ArchiveSearch.fold(item).contains(needle) else { continue }
                out.append(HarvestedItem(
                    meetingID: meeting.card.id,
                    meetingTitle: meeting.card.title,
                    date: meeting.card.date,
                    text: item,
                    timecode: RecapDigest.timecode(in: item)
                ))
                if out.count >= limit { return out }
            }
        }
        return out
    }

    // MARK: - Даты из запроса

    /// `ГГГГ-ММ-ДД` → начало этого дня. Всё остальное — nil: молча принять
    /// непонятную дату значило бы тихо отдать не тот кусок архива.
    public static func day(_ text: String?, calendar: Calendar = .current) -> Date? {
        guard let text else { return nil }
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    /// Верхняя граница включительно: «по 14 августа» — это весь день.
    public static func endOfDay(_ text: String?, calendar: Calendar = .current) -> Date? {
        guard let start = day(text, calendar: calendar) else { return nil }
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start)
    }
}
