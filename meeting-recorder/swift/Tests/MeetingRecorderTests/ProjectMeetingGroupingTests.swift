import XCTest
@testable import PropellerPure

/// Список встреч проекта тянется через месяцы, и режется он крупнее, чем рельс.
/// Каждый случай — про границу, на которой такое деление обычно врёт.
final class ProjectMeetingGroupingTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "ru_RU")
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return cal
    }

    /// Среда, 26 августа 2026.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 12))!
    }

    private func day(_ month: Int, _ day: Int, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func header(_ date: Date) -> String? {
        ProjectMeetingGrouping.group(for: date, now: now, calendar: calendar).header
    }

    func testСамаяСвежаяГруппаБезПодписи() {
        // Понедельник той же недели, что и «сегодня».
        XCTAssertNil(header(day(8, 24)))
        XCTAssertNil(header(now))
    }

    /// Неделя календарная, а не «семь дней назад»: в понедельник «прошлая
    /// неделя» обязана означать прошлую неделю, а не прошлый вторник.
    func testНеделяКалендарнаяАНеСемьДнейНазад() {
        // Воскресенье 23 августа — конец прошлой недели.
        XCTAssertEqual(header(day(8, 23)), "Прошлая неделя")
        // Понедельник 17 августа — её начало.
        XCTAssertEqual(header(day(8, 17)), "Прошлая неделя")
        // 16 августа — уже позапрошлая, и она уезжает в месяц.
        XCTAssertEqual(header(day(8, 16)), "Август")
    }

    func testСтароеНазываетсяМесяцемСЗаглавной() {
        XCTAssertEqual(header(day(7, 3)), "Июль")
        XCTAssertEqual(header(day(1, 3)), "Январь")
    }

    /// «Август» позапрошлого года без года читается как этот.
    func testЧужойГодНазванВместеСМесяцем() {
        XCTAssertEqual(header(day(8, 3, year: 2025)), "Август 2025")
    }

    /// Встреча из будущего — сбитые часы или импорт. Её место наверху, в самой
    /// свежей группе, а не в «Августе 2027».
    func testВстречаИзБудущегоПопадаетВСвежуюГруппу() {
        XCTAssertNil(header(day(12, 31, year: 2027)))
    }

    func testСоседниеВстречиОднойГруппыЛожатсяВОднуКарточку() {
        struct Row { let date: Date }
        let rows = [
            Row(date: day(8, 26)), Row(date: day(8, 24)),   // эта неделя
            Row(date: day(8, 21)), Row(date: day(8, 18)),   // прошлая
            Row(date: day(7, 30)),                          // июль
        ]
        let groups = ProjectMeetingGrouping.grouped(
            rows, date: \.date, now: now, calendar: calendar
        )
        XCTAssertEqual(groups.map(\.group.header), [nil, "Прошлая неделя", "Июль"])
        XCTAssertEqual(groups.map(\.items.count), [2, 2, 1])
    }

    /// Ключ группы устойчив: `ForEach` по нему не должен путать карточки, а два
    /// августа разных лет обязаны быть разными группами.
    func testКлючиГруппРазныеУРазныхМесяцевИЛет() {
        let keys = [day(7, 3), day(8, 3), day(8, 3, year: 2025)].map {
            ProjectMeetingGrouping.group(for: $0, now: now, calendar: calendar).key
        }
        XCTAssertEqual(Set(keys).count, 3, "\(keys)")
    }
}
