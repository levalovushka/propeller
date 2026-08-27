import Foundation

/// The quiet line under a project card: «Вчера · 12 встреч».
///
/// Pure, and here rather than in the view, for the two reasons that always put
/// text here — Russian counts decline by the *last two digits* of the number,
/// and "how long ago" is calendar arithmetic that is wrong twice a year for
/// whoever it happens to. Both are cheap to get wrong in a view body and cheap
/// to pin with a test.
///
/// The mockup's own footers read «Каждую неделю», «Каждый месяц», «По мере
/// необходимости» — cadence, not recency. That is filler text: nothing in the
/// archive knows a project's rhythm, and inventing one would be the interface
/// claiming to know something it does not. What it does know is when the last
/// meeting of the project was.
public enum ProjectCardText {

    /// Whole footer, or nil when the project has nothing to say yet.
    public static func footer(
        meetings: Int,
        last: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let count = meetingCount(meetings)
        guard let last, meetings > 0 else { return count }
        return recency(of: last, now: now, calendar: calendar) + " · " + count
    }

    /// «12 встреч», «2 встречи», «1 встреча», «Пока нет встреч».
    public static func meetingCount(_ count: Int) -> String {
        guard count > 0 else { return "Пока нет встреч" }
        return "\(count) \(declined(count, "встреча", "встречи", "встреч"))"
    }

    /// «Сегодня», «Вчера», «3 дня назад», «Неделю назад», «Давно».
    ///
    /// It stops at «Давно» on purpose. Past a fortnight the exact number is not
    /// what the card is for — a person scanning eight cards is asking which
    /// ones are alive, and «Давно» answers that better than «23 дня назад».
    public static func recency(
        of date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        var cal = calendar
        cal.locale = SidebarDayGrouping.locale
        let days = cal.dateComponents(
            [.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)
        ).day ?? 0

        // A meeting dated in the future is a wrong clock or an import, not a
        // prophecy. Same treatment the rail gives it: today.
        if days <= 0 { return "Сегодня" }
        if days == 1 { return "Вчера" }
        if days < 7 { return "\(days) \(declined(days, "день", "дня", "дней")) назад" }
        if days < 14 { return "Неделю назад" }
        return "Давно"
    }

    /// «22 августа · 45 мин» — первая строка встречи в списке проекта.
    ///
    /// Дата, а не время: в рельсе строки сгруппированы по дням и час отвечает на
    /// «когда», здесь список тянется через месяцы и на «когда» отвечает число.
    /// Длительность — тем же правилом, что и в рельсе (`SidebarMeta`), чтобы
    /// одна и та же встреча не называлась «95 мин» в одном месте и «1 ч 35 мин»
    /// в другом.
    public static func meetingLine(
        date: Date,
        duration: TimeInterval,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        var cal = calendar
        cal.locale = SidebarDayGrouping.locale
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: now)
        let day = (sameYear ? dayMonth : dayMonthYear).string(from: date)
        guard duration > 0 else { return day }
        return day + " · " + SidebarMeta.durationText(duration)
    }

    private static let dayMonth: DateFormatter = formatter("d MMMM")
    private static let dayMonthYear: DateFormatter = formatter("d MMMM yyyy")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = SidebarDayGrouping.locale
        f.dateFormat = format
        return f
    }

    /// Russian counting: the form is chosen by the last two digits, and the
    /// teens are all the third form — 11 встреч, not 11 встреча.
    static func declined(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n = abs(count)
        if n % 100 >= 11 && n % 100 <= 14 { return many }
        switch n % 10 {
        case 1: return one
        case 2, 3, 4: return few
        default: return many
        }
    }
}
