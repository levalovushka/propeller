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

    /// Сколько человек было — **длина списка, который откроется под чипом**.
    ///
    /// Одно правило на число и на список: чип теперь нажимается, и число,
    /// посчитанное отдельно от рядов, разошлось бы с ними в первый же день.
    /// Считает `MeetingRoster.rows`, здесь только длина.
    ///
    /// **До 2026-08-27 здесь стоял `max(приглашённые, подписи)`**, и доккоммент
    /// защищал этот максимум: календарь знает состав точнее, но теряет гостя без
    /// карточки в контактах, поэтому брали больший из двух приблизительных
    /// списков. Решение владельца отменило основание: список — про участников,
    /// приглашённые в него не входят и годятся запасом. Цена измерена на живом
    /// архиве: на **50 встречах из 149** число упадёт, вырасти оно не может ни
    /// на одной.
    ///
    /// Плейсхолдеры (`Speaker 2`, «Собеседник») считаются **только там, где из
    /// звонилки не приехало ничего**: тогда за каждым стоит живой человек, чьего
    /// имени мы не знаем, а спросили «сколько», не «кто». Где плитки есть, они
    /// же и есть ответ, а плейсхолдер — секунда без плитки у того же человека
    /// (замер и правило — `MeetingRoster`, «Кластер — ряд только там, где плиток
    /// нет»).
    public static func count(_ rows: [MeetingRoster.Row]) -> Int { rows.count }

    /// Слот проекта — словом или одним «плюсом» (312:11142).
    ///
    /// Словом — только у встречи, о проекте которой на экране не сказано
    /// ничего: ни метки, ни предложения. Тогда «+ Проект» единственное, что о
    /// проектах вообще сообщает, и он обязан читаться. Как только рядом стоит
    /// имя проекта или приехало предложение (`plan-projects.md` §3 — его
    /// пунктирный чип ждёт макета и встанет в эту же строку), слово «Проект»
    /// повторяет уже сказанное: слот сжимается до значка, а значок виден
    /// только под курсором.
    public static func projectSlotCollapsed(tagged: Int, hasSuggestion: Bool) -> Bool {
        tagged > 0 || hasSuggestion
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
