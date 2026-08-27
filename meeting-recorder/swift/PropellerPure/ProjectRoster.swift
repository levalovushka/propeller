import Foundation

/// Кто ходит в этот проект — Figma `project/participants-tab` (256:7467).
///
/// Первая поверхность, где люди из `plan-people.md` видны кучей, и собирается
/// она из того же, из чего собран поиск по людям: **у встречи нет поля
/// «участники»**. Есть подписи в расшифровке — и там по имени зовут ровно
/// одного, владельца микрофона, остальные остаются `Speaker N`, — и есть
/// приглашённые из календаря, которых нет у трети архива. Честный образец —
/// `MeetingLookup.passesPeople`: он объединяет источники и объясняет почему.
///
/// Заголовок встречи третьим источником здесь **не берётся**. Поиску он нужен
/// («спросил про Даню, а встреча называется „1×1 с Даней“» — худший ответ, если
/// промолчать), а списку — нет: вытащить «Даней» из названия значит завести
/// участника в творительном падеже. Поиск сравнивает основы и ошибается в свою
/// пользу; список показывает строку и ошибётся в чужую.
public enum ProjectRoster {

    /// Одна встреча в том виде, в каком по ней считают состав. Тексты уже
    /// прочитаны — ходить на диск это место не умеет.
    public struct Meeting: Equatable, Sendable {
        public let id: String
        /// Подписи расшифровки: `RecapDocument.participants(fromTranscript:)`.
        public let speakers: [String]
        /// `calendarMeta.attendees`.
        public let invited: [String]

        public init(id: String, speakers: [String] = [], invited: [String] = []) {
            self.id = id
            self.speakers = speakers
            self.invited = invited
        }
    }

    /// Человек и то, что о нём известно по проекту.
    public struct Person: Equatable, Identifiable, Sendable {
        /// Написание, которым его показывают.
        public let name: String
        /// Во скольких встречах проекта он назван.
        public let meetings: Int
        /// Назывался ли он хоть раз голосом, а не только списком приглашённых.
        /// Различие честное: приглашённый мог и не прийти.
        public let spoke: Bool

        public var id: String { name }

        public init(name: String, meetings: Int, spoke: Bool) {
            self.name = name
            self.meetings = meetings
            self.spoke = spoke
        }
    }

    /// Состав проекта: сначала те, кто чаще, при равенстве — по алфавиту.
    ///
    /// Два написания одного имени («Марина» из расшифровки и «Marina» из
    /// календаря) сходятся по свёртке `PersonCanon` — той же, которой конспект
    /// приводит имена к составу ленты. Побеждает написание, которым человека
    /// назвали **голосом**: подпись в ленте — это то, что читатель найдёт в
    /// расшифровке глазами.
    ///
    /// Чего свёртка не делает и здесь: «Александр» и «Alexander» она не сошьёт
    /// — это перевод имени, а не его написание.
    public static func roster(of meetings: [Meeting]) -> [Person] {
        struct Tally {
            var spokenName: String?
            var invitedName: String?
            var meetings: Set<String> = []
            var spoke = false
        }
        var tallies: [String: Tally] = [:]
        var order: [String] = []

        func note(_ raw: String, in meeting: String, spoken: Bool) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let key = PersonCanon.fold(name)
            guard !key.isEmpty else { return }
            if tallies[key] == nil {
                tallies[key] = Tally()
                order.append(key)
            }
            tallies[key]?.meetings.insert(meeting)
            if spoken {
                tallies[key]?.spoke = true
                if tallies[key]?.spokenName == nil { tallies[key]?.spokenName = name }
            } else if tallies[key]?.invitedName == nil {
                tallies[key]?.invitedName = name
            }
        }

        for meeting in meetings {
            for name in meeting.speakers { note(name, in: meeting.id, spoken: true) }
            for name in meeting.invited { note(name, in: meeting.id, spoken: false) }
        }

        return order.compactMap { key -> Person? in
            guard let tally = tallies[key], let name = tally.spokenName ?? tally.invitedName
            else { return nil }
            return Person(name: name, meetings: tally.meetings.count, spoke: tally.spoke)
        }
        .sorted {
            if $0.meetings != $1.meetings { return $0.meetings > $1.meetings }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Вторая строка карточки человека: «12 встреч» или «Приглашён, не говорил».
    ///
    /// Различие названо словами, а не значком: «приглашён» и «был» — разные
    /// факты, и склеить их значило бы сказать про человека то, чего архив не
    /// знает.
    public static func subtitle(for person: Person) -> String {
        person.spoke
            ? ProjectCardText.meetingCount(person.meetings)
            : "Приглашён · " + ProjectCardText.meetingCount(person.meetings)
    }
}
