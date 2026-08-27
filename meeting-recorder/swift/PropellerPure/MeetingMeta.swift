import Foundation

/// Строка атрибутов над именем встречи — Figma 312:11129.
///
/// Мелкие чипы: когда встреча была, сколько человек в ней участвовало, к какому
/// проекту относится. Это не подписи к полям, а сами факты — поэтому «22 авг,
/// 16:30», а не «Дата: 22 авг».
public enum MeetingMeta {

    /// «22 авг, 16:30». Год появляется, только если он не нынешний: в архиве за
    /// эту неделю он был бы шумом, а в прошлогодней встрече — единственным, что
    /// отличает её от вчерашней.
    public static func when(
        _ date: Date, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = (sameYear ? dayShortMonth : dayShortMonthYear).string(from: date)
        return stripped(day) + ", " + time.string(from: date)
    }

    /// «6 человек», «1 человек», «2 человека». `nil` — чипа нет вовсе: «0
    /// человек» это не факт о встрече, а сообщение о том, что мы не знаем.
    public static func people(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(personWord(count))"
    }

    /// Сколько человек было — по именам, а не по числу источников.
    ///
    /// Приглашённые и говорившие **не складываются**. Один и тот же человек
    /// приходит из календаря как «Levon Lobanov», а из диаризации как «Левон»,
    /// и сложить их — значит посчитать его дважды. `MeetingLookup` их всё-таки
    /// объединяет, но там ищут, и лишнее совпадение безобидно; здесь считают, и
    /// лишняя единица — враньё.
    ///
    /// Берётся **больший** из двух списков, а не календарный. Календарь знает
    /// состав точнее — но не полнее: `CalendarService` складывает имена как
    /// `attendees.compactMap { $0.name }`, а у гостя без карточки в контактах
    /// имени нет, и он молча выпадает. Отказавшиеся, наоборот, остаются. Взяв
    /// календарь как единственную правду, мы отвечали бы «2 человека» на
    /// встрече, где слышно шестерых. Максимум не суммирует и не опускается
    /// ниже того, что прозвучало.
    ///
    /// Плейсхолдеры (`Speaker 2`, «Собеседник») считаются: за каждым стоит
    /// живой человек, чьего имени мы не знаем, — а нас спросили «сколько», а не
    /// «кто».
    ///
    /// **Это временная мера.** Расчёт владельца (2026-08-27) — тянуть точный
    /// состав из самого звонка: сперва из Zoom, дальше учиться так же снимать
    /// его на других площадках. Когда список приедет оттуда, он станет
    /// единственным источником, и максимум из двух приблизительных списков
    /// будет не нужен.
    public static func count(speakers: [String], invited: [String]) -> Int {
        max(distinct(invited), distinct(speakers))
    }

    private static func distinct(_ names: [String]) -> Int {
        var seen = Set<String>()
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }
            seen.insert(trimmed)
        }
        return seen.count
    }

    private static func personWord(_ count: Int) -> String {
        let tens = count % 100
        if tens >= 11, tens <= 14 { return "человек" }
        switch count % 10 {
        case 1: return "человек"
        case 2, 3, 4: return "человека"
        default: return "человек"
        }
    }

    // Русские сокращения месяцев идут с точкой («22 авг.»), а в макете её нет:
    // в чипе рядом со временем точка читается как конец предложения.
    private static let dayShortMonth = formatter("d MMM")
    private static let dayShortMonthYear = formatter("d MMM yyyy")
    private static let time = formatter("HH:mm", posix: true)

    private static func formatter(_ format: String, posix: Bool = false) -> DateFormatter {
        let f = DateFormatter()
        f.locale = posix ? Locale(identifier: "en_US_POSIX") : Locale(identifier: "ru_RU")
        f.dateFormat = format
        return f
    }
}

extension MeetingMeta {
    /// То же, что `when`, но без точки в сокращении месяца.
    static func stripped(_ text: String) -> String { text.replacingOccurrences(of: ".", with: "") }
}
