import Foundation

/// How the rail cuts the archive into days, and what it writes above each one.
///
/// The comps group by *day*, not by the coarse Сегодня / Неделя / Ранее buckets
/// the old list used, and they leave the newest group unlabelled — a header
/// saying «Сегодня» above the meeting that ended nine minutes ago is a word
/// nobody reads. Everything older earns a date, because that is the moment the
/// date stops being obvious.
///
/// Pure, and here rather than in the view, because "which day is that" is all
/// calendar arithmetic and time zones — the class of thing that is wrong twice a
/// year and only for the people it happens to.
public enum SidebarDayGrouping {

    public struct Day: Equatable, Sendable {
        /// Stable key for the group — the start of that day.
        public let key: String
        /// What the rail writes above it. Nil for today.
        public let header: String?

        public init(key: String, header: String?) {
            self.key = key
            self.header = header
        }
    }

    public static let locale = Locale(identifier: "ru_RU")

    /// The day `date` belongs to, seen from `now`.
    public static func day(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Day {
        var cal = calendar
        cal.locale = locale
        let start = cal.startOfDay(for: date)
        let today = cal.startOfDay(for: now)
        let days = cal.dateComponents([.day], from: start, to: today).day ?? 0
        return Day(key: keyFormatter.string(from: start), header: header(days: days, date: date, now: now, calendar: cal))
    }

    private static func header(days: Int, date: Date, now: Date, calendar: Calendar) -> String? {
        // Future-dated meetings can exist — a machine whose clock was wrong, or
        // an import. Treat them as today rather than writing «через −1 день».
        if days <= 0 { return nil }
        if days == 1 { return "Вчера, " + dayMonth.string(from: date) }
        if days < 7 {
            let weekday = weekdayName.string(from: date)
            return weekday.prefix(1).uppercased() + weekday.dropFirst() + ", " + dayMonth.string(from: date)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear ? dayMonth.string(from: date) : dayMonthYear.string(from: date)
    }

    private static let keyFormatter: DateFormatter = formatter("yyyy-MM-dd", posix: true)
    private static let dayMonth: DateFormatter = formatter("d MMMM")
    private static let dayMonthYear: DateFormatter = formatter("d MMMM yyyy")
    private static let weekdayName: DateFormatter = formatter("EEEE")

    private static func formatter(_ format: String, posix: Bool = false) -> DateFormatter {
        let f = DateFormatter()
        f.locale = posix ? Locale(identifier: "en_US_POSIX") : locale
        f.dateFormat = format
        return f
    }
}

/// «17:30 · 45 мин» — the quiet first line of a meeting row.
public enum SidebarMeta {

    public static func line(start: Date, duration: TimeInterval, calendar: Calendar = .current) -> String {
        let time = timeFormatter.string(from: start)
        guard duration > 0 else { return time }
        return time + " · " + durationText(duration)
    }

    /// Minutes, then hours once there are enough of them. A meeting that ran
    /// 95 minutes is «1 ч 35 мин», not «95 мин» — nobody divides in their head.
    public static func durationText(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes < 1 { return "меньше минуты" }
        if totalMinutes < 60 { return "\(totalMinutes) мин" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours) ч" : "\(hours) ч \(minutes) мин"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
}
