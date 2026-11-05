import Foundation

/// # С чем подошли к встрече
///
/// Пока идёт запись, в панели стоят решения прошлой встречи той же серии —
/// `plan-projects.md` §4.5. Собраны они **механически**: это пункты «Решения» и
/// «Задачи» из её конспекта как есть, без второго прохода модели. Если для
/// сжатия нужна модель, решения были многословны на входе, и чинится это там.
///
/// Задача — это решение, у которого есть исполнитель, поэтому отдельного блока
/// у неё нет: она идёт в том же списке, после решений (решение владельца
/// 2026-11-05).
///
/// **Серия — это `seriesID` из календаря и другой день.** `seriesID` у
/// EventKit есть у любого события, не только у повторяющегося, и на архиве
/// (замер 2026-11-05, 178 встреч) шесть из одиннадцати «серий» с двумя
/// встречами — одна разовая встреча, записанная в два куска в тот же день.
/// Для такой «прошлым разом» оказался бы первый кусок той же встречи. Другой
/// календарный день отсекает ровно их: оставшиеся пять серий — повторяющиеся.
public enum PreviousDecisions {

    public struct Meeting: Equatable, Sendable {
        public let id: String
        /// `calendarMeta.seriesID`.
        public let seriesID: String?
        public let date: Date
        /// Есть ли у встречи готовый конспект — читать решения больше не из чего.
        public let hasSummary: Bool

        public init(id: String, seriesID: String?, date: Date, hasSummary: Bool) {
            self.id = id
            self.seriesID = seriesID
            self.date = date
            self.hasSummary = hasSummary
        }
    }

    /// Встреча, чьи решения показывать, — или nil, и тогда блока нет вовсе.
    ///
    /// Последняя из более ранних встреч серии **с конспектом**. Прошлый раз,
    /// который ещё расшифровывается, пропускается в пользу предыдущего: дата у
    /// блока подписана, так что он не притворяется свежее, чем есть.
    public static func source(
        for current: Meeting,
        in archive: [Meeting],
        calendar: Calendar = .current
    ) -> Meeting? {
        guard let series = current.seriesID, !series.isEmpty else { return nil }
        let today = calendar.startOfDay(for: current.date)
        return archive
            .filter {
                $0.id != current.id
                    && $0.seriesID == series
                    && $0.hasSummary
                    && calendar.startOfDay(for: $0.date) < today
            }
            .max { $0.date < $1.date }
    }

    /// Подпись блока: «Решения с прошлого раза, 29 окт». Дата нужна всегда —
    /// прошлый раз мог быть и месяц назад, и подпись не должна притворяться
    /// свежее, чем есть.
    public static func heading(
        for source: Meeting, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        "Решения с прошлого раза, " + MeetingMeta.day(source.date, now: now, calendar: calendar)
    }

    /// Что показать из конспекта: решения, за ними задачи. Пустой ответ — блока
    /// нет: подпись «Решения с прошлого раза» над пустотой обещала бы то, чего
    /// не было.
    ///
    /// Чекбоксы снимаются: квадрат у задачи убран 2026-08-31, но конспекты до
    /// этого дня лежат на дисках с `[x]` и `[ ]`, и на экране они печатались бы
    /// скобками.
    public static func items(from digest: RecapDigest) -> [String] {
        (digest.decisions + digest.tasks)
            .map { item in
                var text = item.trimmingCharacters(in: .whitespacesAndNewlines)
                for box in ["[x] ", "[X] ", "[ ] "] where text.hasPrefix(box) {
                    text = String(text.dropFirst(box.count))
                }
                return text
            }
            .filter { !$0.isEmpty }
    }
}
