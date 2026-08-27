import XCTest
@testable import PropellerPure

final class MeetingMetaTests: XCTestCase {

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // Своя зона, а не фиксированная: форматтер под замером тоже читает её,
        // и прибитая Москва развалила бы тест на любой другой машине.
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: iso)!
    }

    // MARK: - Когда

    func testTheDateReadsTheWayTheCompsWroteIt() {
        let when = MeetingMeta.when(date("2026-08-22 16:30"), now: date("2026-08-27 12:00"))
        XCTAssertEqual(when, "22 авг, 16:30")
    }

    /// Русское сокращение месяца идёт с точкой, и рядом со временем она читается
    /// как конец предложения. В макете её нет.
    func testTheMonthDoesNotEndInAFullStop() {
        XCTAssertFalse(MeetingMeta.when(date("2026-08-22 16:30"), now: date("2026-08-27 12:00"))
            .contains("."))
    }

    /// Год — не шум и не украшение: в этом году он не отличает ничего, в
    /// прошлом отличает всё.
    func testAMeetingFromAnotherYearSaysWhichYear() {
        let when = MeetingMeta.when(date("2025-11-03 09:05"), now: date("2026-08-27 12:00"))
        XCTAssertEqual(when, "3 нояб 2025, 09:05")
    }

    // MARK: - Сколько человек

    func testTheCountIsDeclinedTheWayRussianDeclinesIt() {
        XCTAssertEqual(MeetingMeta.people(1), "1 человек")
        XCTAssertEqual(MeetingMeta.people(2), "2 человека")
        XCTAssertEqual(MeetingMeta.people(4), "4 человека")
        XCTAssertEqual(MeetingMeta.people(5), "5 человек")
        XCTAssertEqual(MeetingMeta.people(6), "6 человек")
        XCTAssertEqual(MeetingMeta.people(11), "11 человек")
        XCTAssertEqual(MeetingMeta.people(21), "21 человек")
        XCTAssertEqual(MeetingMeta.people(22), "22 человека")
        XCTAssertEqual(MeetingMeta.people(112), "112 человек")
    }

    /// «0 человек» — это не факт о встрече, а признание, что мы не знаем.
    func testNobodyKnownMeansNoChipAtAll() {
        XCTAssertNil(MeetingMeta.people(0))
    }

    /// Календарь знает состав, диаризация знает только тех, кто говорил, — и
    /// один человек приходит из них под разными именами. Складывать нельзя.
    func testTheCalendarWinsAndTheTwoRostersAreNeverAdded() {
        let count = MeetingMeta.count(
            speakers: ["Левон", "Собеседник"],
            invited: ["Levon Lobanov", "Ilyas Aitkulov", "Полина"]
        )
        XCTAssertEqual(count, 3)
    }

    func testWithoutACalendarTheSpeakersAreTheAnswer() {
        XCTAssertEqual(MeetingMeta.count(speakers: ["Левон", "Speaker 2"], invited: []), 2)
    }

    /// Метка спикера повторяется в каждой реплике — считаются люди, а не реплики.
    func testTheSameSpeakerCountsOnce() {
        let speakers = ["Левон", "Собеседник", "Левон", " левон ", "Собеседник"]
        XCTAssertEqual(MeetingMeta.count(speakers: speakers, invited: []), 2)
    }

    /// `Speaker 2` — живой человек, чьего имени мы не знаем. Спросили «сколько»,
    /// а не «кто», поэтому он считается.
    func testAnUnnamedSpeakerIsStillAPerson() {
        XCTAssertEqual(MeetingMeta.count(speakers: ["Speaker 1", "Speaker 2"], invited: []), 2)
    }

    func testAnEmptyMeetingCountsNobody() {
        XCTAssertEqual(MeetingMeta.count(speakers: ["", "  "], invited: []), 0)
    }
}
