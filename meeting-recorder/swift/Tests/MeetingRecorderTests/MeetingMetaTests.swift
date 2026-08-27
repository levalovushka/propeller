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

    // MARK: - Слот проекта

    /// Слово «Проект» — только когда о проекте на экране не сказано ничего.
    func testTheEmptySlotSpellsItselfOutOnlyWhenNothingElseSaysProject() {
        XCTAssertFalse(MeetingMeta.projectSlotCollapsed(tagged: 0, hasSuggestion: false))
    }

    /// Рядом с именем проекта слово «Проект» повторяет уже сказанное.
    func testATaggedMeetingKeepsOnlyThePlus() {
        XCTAssertTrue(MeetingMeta.projectSlotCollapsed(tagged: 1, hasSuggestion: false))
    }

    /// Предложение — тоже разговор о проекте, даже пока метки нет.
    func testASuggestionAloneIsEnoughToCollapseTheSlot() {
        XCTAssertTrue(MeetingMeta.projectSlotCollapsed(tagged: 0, hasSuggestion: true))
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

    /// Число в чипе — длина списка, который под ним откроется. Одно правило на
    /// оба, потому что чип нажимается: посчитанное отдельно от рядов разошлось
    /// бы с ними в первый же день.
    func testTheNumberIsTheLengthOfTheListThatOpens() {
        let rows = MeetingRoster.rows(.init(
            spoken: ["Левон", "Speaker 2", "Speaker 3"], ownerName: "Левон"
        ))
        XCTAssertEqual(MeetingMeta.count(rows), rows.count)
        XCTAssertEqual(MeetingMeta.people(MeetingMeta.count(rows)), "3 человека")
    }

    /// Приглашённые в состав не входят. До 2026-08-27 здесь стоял максимум из
    /// двух списков, и на живом архиве он завышал число на 50 встречах из 149.
    func testInvitedDoNotSwellTheNumber() {
        let rows = MeetingRoster.rows(.init(
            spoken: ["Левон", "Собеседник"],
            invited: ["Levon Lobanov", "Ilyas Aitkulov", "Полина"],
            ownerName: "Левон"
        ))
        XCTAssertEqual(MeetingMeta.count(rows), 2)
    }

    /// Метка спикера повторяется в каждой реплике — считаются люди, а не реплики.
    func testTheSameSpeakerCountsOnce() {
        let rows = MeetingRoster.rows(.init(
            spoken: ["Левон", "Собеседник", "Левон", " левон ", "Собеседник"],
            ownerName: "Левон"
        ))
        XCTAssertEqual(MeetingMeta.count(rows), 2)
    }

    /// О встрече не известно ничего — чипа нет вовсе, а не «1 человек».
    /// Владелец единственный ряд не из данных, и на нерасшифрованной встрече он
    /// обещал бы состав там, где его ещё не считали.
    func testAMeetingNothingIsKnownAboutHasNoChip() {
        XCTAssertEqual(MeetingMeta.count(MeetingRoster.rows(.init(ownerName: "Левон"))), 0)
        XCTAssertNil(MeetingMeta.people(0))
    }
}
