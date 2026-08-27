import Foundation

/// Кого приложение предлагает завести проектом, а кого — молча не предлагает.
///
/// Центральный вызов спеки (`plan-projects.md` §3): научиться определять проект
/// раз за разом — и **правильно не-определять**, когда встреча случайная.
/// Бесит не ошибка, а навязчивая ошибка, поэтому весь модуль устроен как
/// перечень причин промолчать.
///
/// # Что считается похожестью
///
/// Первая версия — то, что уже лежит на диске (§6): **серия календаря, название
/// события, состав**. Серия — самый сильный сигнал и единственный не текстовый:
/// еженедельный синк это не набор похожих встреч, это одно событие с одним
/// идентификатором. Эмбеддинги — кандидат не первой версии, и их здесь нет.
///
/// # Чего модуль не делает
///
/// - **Не предлагает по одной встрече.** Проект — это повторяющиеся встречи;
///   одна встреча повторением не является, сколько бы имя ни обещало.
/// - **Не предлагает безымянного.** «Встреча», «Созвон», «Zoom Meeting» — имя,
///   которого хватает календарю и не хватает проекту. Безымянный проект хуже
///   отсутствующего (§3, правило 5).
/// - **Не возвращает заглушенное.** Крестик на предложении — навсегда (§3,
///   правило 3): второй раз то же самое не спрашивают.
/// - **Не ставит второй проект.** Встреча, у которой проект уже есть, в
///   предложения не попадает вовсе (§3, правило 4).
public enum ProjectCandidate {

    /// Встреча в том виде, в каком по ней ищут повторение. Тексты уже прочитаны.
    public struct Meeting: Equatable, Sendable {
        public let id: String
        /// Название встречи — то, что видит человек.
        public let title: String
        /// Название события календаря, если встреча пришла из него.
        public let eventTitle: String?
        /// `calendarMeta.seriesID` — идентификатор серии.
        public let seriesID: String?
        /// Проекты, которыми встреча уже помечена.
        public let projects: [String]
        public let date: Date

        public init(
            id: String, title: String, eventTitle: String? = nil, seriesID: String? = nil,
            projects: [String] = [], date: Date
        ) {
            self.id = id
            self.title = title
            self.eventTitle = eventTitle
            self.seriesID = seriesID
            self.projects = projects
            self.date = date
        }
    }

    /// Предложение: как назвать проект и какие встречи в него уйдут.
    public struct Suggestion: Equatable, Identifiable, Sendable {
        /// Ключ связки — по нему её глушат навсегда. Устойчив между запусками:
        /// это серия или свёрнутое имя, а не позиция в списке.
        public let key: String
        /// Имя, которое предлагается. Из названия, а не выдуманное.
        public let name: String
        /// Встречи, которые уйдут в проект при согласии, от новых к старым.
        /// Это и есть ретро-привязка из §3 — она не отдельный шаг, а тот же
        /// список, которым предложение обосновано.
        public let meetings: [String]

        public var id: String { key }

        public init(key: String, name: String, meetings: [String]) {
            self.key = key
            self.name = name
            self.meetings = meetings
        }
    }

    /// Сколько похожих встреч рождают предложение.
    ///
    /// Две, а не три (`plan-projects.md` §10.2 оставляет вопрос открытым): на
    /// двойке предложение появляется на второй встрече серии — то есть тогда,
    /// когда человек как раз и понимает, что это регулярка. На тройке первое
    /// предложение приходит через две недели после начала, когда контекст уже
    /// потерян. Цена ошибки при этом одинаковая — один крестик.
    public static let repeats = 2

    /// Предложения по архиву. Пусто — предлагать нечего, и это нормальный ответ.
    ///
    /// - Parameter silenced: ключи связок, на которых уже сказали «нет».
    public static func suggestions(
        silenced: Set<String> = [],
        for meetings: [Meeting]
    ) -> [Suggestion] {
        // Встреча, у которой проект уже есть, в поиске повторений не участвует
        // ни как повод, ни как добыча: у неё спросили и ответили.
        let loose = meetings.filter { $0.projects.isEmpty }
        var buckets: [String: (name: String, meetings: [Meeting])] = [:]
        var order: [String] = []

        func put(_ key: String, name: String, meeting: Meeting) {
            if buckets[key] == nil {
                buckets[key] = (name, [])
                order.append(key)
            }
            buckets[key]?.meetings.append(meeting)
        }

        for meeting in loose {
            // Серия сильнее названия: два «Дейлика» из разных серий — два
            // разных дейлика, и складывать их в один проект значило бы слепить
            // чужие команды по совпадению слова.
            if let series = meeting.seriesID, !series.isEmpty {
                guard let name = self.name(of: meeting) else { continue }
                put("series:" + series, name: name, meeting: meeting)
                continue
            }
            guard let name = self.name(of: meeting) else { continue }
            put("title:" + ArchiveSearch.fold(name), name: name, meeting: meeting)
        }

        return order.compactMap { key -> Suggestion? in
            guard !silenced.contains(key), let bucket = buckets[key],
                  bucket.meetings.count >= repeats
            else { return nil }
            return Suggestion(
                key: key,
                name: bucket.name,
                meetings: bucket.meetings.sorted { $0.date > $1.date }.map(\.id)
            )
        }
        .sorted { lhs, rhs in
            if lhs.meetings.count != rhs.meetings.count { return lhs.meetings.count > rhs.meetings.count }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Имя, которое можно предложить, — или nil, и тогда предложения нет вовсе.
    ///
    /// Берётся название события календаря, а при его отсутствии — название
    /// встречи. Название встречи модель могла переписать, но переписывает она
    /// его в осмысленное, а не в мусорное.
    static func name(of meeting: Meeting) -> String? {
        for candidate in [meeting.eventTitle, meeting.title] {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty, !isJunk(trimmed)
            else { continue }
            return trimmed
        }
        return nil
    }

    /// Название, которое ничего не называет.
    ///
    /// Стоп-список, а не эвристика по длине: «ЦД» — законное имя проекта из двух
    /// букв, а «Новая встреча» — не имя из тринадцати. Сравнение по свёртке,
    /// поэтому «СОЗВОН» и «созвон.» — одно и то же.
    static func isJunk(_ title: String) -> Bool {
        let folded = ArchiveSearch.fold(title)
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard !folded.isEmpty else { return true }
        if junk.contains(folded) { return true }
        // «Запись 26.08.2026, 18:20» — имя, которое приложение дало само, когда
        // называть было нечем. Предлагать проект по нему — предлагать проект по
        // дате. Цифра после слова обязательна: «Записи подкаста» — законное имя,
        // и отбрасывать его по одному корню было бы той самой навязчивостью.
        return autoTitle.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)) != nil
    }

    /// Имя, которое приложение дало встрече само: «Запись 26.08.2026, 18:20».
    private static let autoTitle = try! NSRegularExpression(pattern: #"^запись\s+\d"#)

    private static let junk: Set<String> = Set(
        [
            "встреча", "новая встреча", "созвон", "звонок", "митинг", "синк",
            "разговор", "обсуждение", "беседа", "болталка", "без названия",
            "meeting", "new meeting", "call", "zoom meeting", "google meet",
            "untitled", "no title", "sync", "quick sync", "catch up", "chat",
        ].map { ArchiveSearch.fold($0) }
    )
}
