import Foundation

/// Как список встреч проекта режется на группы — Figma 256:8830.
///
/// Макет показывает одну карточку без заголовка и следом «Прошлая неделя»:
/// свежее лежит первым и в подписи не нуждается, у остального подпись есть. То
/// же правило, что у рельса (`SidebarDayGrouping`), только шаг крупнее — здесь
/// список тянется через месяцы, и резать его по дням значило бы получить
/// двадцать карточек по одной строке.
///
/// Названия групп не выдуманы: «Прошлая неделя» стоит в макете, дальше — имя
/// месяца, то есть данные, а не слово, которое кто-то придумал. Год добавляется,
/// когда он не этот, — иначе «Август» позапрошлого года читается как этот.
public enum ProjectMeetingGrouping {

    public struct Group: Equatable, Sendable {
        /// Устойчивый ключ группы — по нему `ForEach` не путает карточки.
        public let key: String
        /// Что написано над карточкой. Nil у самой свежей группы.
        public let header: String?

        public init(key: String, header: String?) {
            self.key = key
            self.header = header
        }
    }

    /// Группа, которой принадлежит встреча.
    public static func group(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Group {
        var cal = calendar
        cal.locale = SidebarDayGrouping.locale
        // Понедельник: неделя здесь — календарная, а не «семь дней назад».
        // «Прошлая неделя» в понедельник обязана означать прошлую неделю, а не
        // прошлый вторник.
        cal.firstWeekday = 2

        let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)
        if let thisWeek, thisWeek.contains(date) || date > thisWeek.end {
            return Group(key: "current", header: nil)
        }
        if let previous = cal.date(byAdding: .weekOfYear, value: -1, to: now),
           let lastWeek = cal.dateInterval(of: .weekOfYear, for: previous),
           lastWeek.contains(date) {
            return Group(key: "last-week", header: "Прошлая неделя")
        }

        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: now)
        let name = (sameYear ? monthName : monthYearName).string(from: date)
        return Group(
            key: monthKey.string(from: date),
            header: name.prefix(1).uppercased() + name.dropFirst()
        )
    }

    /// Встречи, разложенные по группам. Порядок групп — по первому появлению,
    /// порядок внутри группы — тот, в котором пришли: сортировать здесь нечего,
    /// вызывающий уже отдал список в нужном порядке.
    ///
    /// Одинаковый ключ **сливается, даже если встречи не подряд**. Соседство
    /// зависит от того, отсортирован ли вход, а ключ группы уходит в
    /// `ForEach(id:)` — две группы с одним ключом там не список, а
    /// неопределённое поведение. Договорённость «вызывающий сортирует» слишком
    /// тонка, чтобы держать на ней вид.
    public static func grouped<Item>(
        _ items: [Item],
        date: (Item) -> Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [(group: Group, items: [Item])] {
        var out: [(group: Group, items: [Item])] = []
        var index: [String: Int] = [:]
        for item in items {
            let group = self.group(for: date(item), now: now, calendar: calendar)
            if let at = index[group.key] {
                out[at].items.append(item)
            } else {
                index[group.key] = out.count
                out.append((group, [item]))
            }
        }
        return out
    }

    private static let monthName: DateFormatter = formatter("LLLL")
    private static let monthYearName: DateFormatter = formatter("LLLL yyyy")
    private static let monthKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = SidebarDayGrouping.locale
        f.dateFormat = format
        return f
    }
}
