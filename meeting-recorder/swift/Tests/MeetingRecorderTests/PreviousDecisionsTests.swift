import XCTest
import PropellerPure

/// Блок «Решения с прошлого раза» на экране записи. Каждый случай здесь — то,
/// что человек увидел бы на месте этого блока, если бы правило ошиблось.
final class PreviousDecisionsTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }()

    private func day(_ d: Int, _ h: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))!
    }

    private func meeting(
        _ id: String, series: String? = "S", on date: Date, summary: Bool = true
    ) -> PreviousDecisions.Meeting {
        .init(id: id, seriesID: series, date: date, hasSummary: summary)
    }

    func testTheLastEarlierMeetingOfTheSeriesIsTheSource() {
        let now = meeting("now", on: day(5), summary: false)
        let archive = [
            meeting("a", on: day(1)),
            meeting("b", on: day(3)),
            meeting("other", series: "X", on: day(4)),
            now,
        ]
        XCTAssertEqual(PreviousDecisions.source(for: now, in: archive, calendar: calendar)?.id, "b")
    }

    func testAMeetingWithoutASeriesShowsNoBlock() {
        let now = meeting("now", series: nil, on: day(5))
        let archive = [meeting("a", series: nil, on: day(1)), now]
        XCTAssertNil(PreviousDecisions.source(for: now, in: archive, calendar: calendar))
    }

    func testTheFirstMeetingOfASeriesShowsNoBlock() {
        let now = meeting("now", on: day(5))
        XCTAssertNil(PreviousDecisions.source(for: now, in: [now], calendar: calendar))
    }

    /// Разовая встреча, записанная в два куска: на живом архиве таких шесть из
    /// одиннадцати «серий». Первый кусок — не прошлый раз.
    func testAnEarlierRecordingOfTheSameDayIsNotTheLastTime() {
        let now = meeting("now", on: day(5, 15))
        let archive = [meeting("morning", on: day(5, 11)), now]
        XCTAssertNil(PreviousDecisions.source(for: now, in: archive, calendar: calendar))
    }

    func testALaterMeetingIsNeverTheLastTime() {
        let now = meeting("now", on: day(5))
        let archive = [meeting("future", on: day(8)), now]
        XCTAssertNil(PreviousDecisions.source(for: now, in: archive, calendar: calendar))
    }

    func testALastTimeStillBeingSummarisedFallsBackToTheOneBefore() {
        let now = meeting("now", on: day(5))
        let archive = [
            meeting("a", on: day(1)),
            meeting("pending", on: day(4), summary: false),
            now,
        ]
        XCTAssertEqual(PreviousDecisions.source(for: now, in: archive, calendar: calendar)?.id, "a")
    }

    func testTheHeadingSaysWhenTheLastTimeWas() {
        let source = meeting("b", on: calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 11))!)
        let heading = PreviousDecisions.heading(for: source, now: day(5), calendar: calendar)
        XCTAssertTrue(heading.hasPrefix("Решения с прошлого раза, 29 "), heading)
        XCTAssertFalse(heading.contains("2026"), heading)
    }

    func testTasksFollowDecisionsInOneList() {
        let digest = RecapDigest.parse("""
        # Встреча — рекап

        ## Решения
        - Отказались от барабана.

        ## Задачи
        - **Даня** — уточнить смету.

        ## Открытые вопросы
        - Кто согласует анимации?
        """)
        XCTAssertEqual(PreviousDecisions.items(from: digest), [
            "Отказались от барабана.",
            "**Даня** — уточнить смету.",
        ])
    }

    /// Конспекты до 2026-08-31 несут чекбоксы у задач.
    func testOldCheckboxesAreNotPrintedAsBrackets() {
        let digest = RecapDigest.parse("""
        ## Задачи
        - [x] **Костя** — выложить прошлый прогон.
        - [ ] Собрать список блоков.
        """)
        XCTAssertEqual(PreviousDecisions.items(from: digest), [
            "**Костя** — выложить прошлый прогон.",
            "Собрать список блоков.",
        ])
    }

    func testARecapWithNeitherDecisionsNorTasksShowsNoBlock() {
        let digest = RecapDigest.parse("""
        ## Итог
        Поговорили.

        ## Открытые вопросы
        - Что дальше?
        """)
        XCTAssertTrue(PreviousDecisions.items(from: digest).isEmpty)
    }
}
