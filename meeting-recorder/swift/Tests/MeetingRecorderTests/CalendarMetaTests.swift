import XCTest
@testable import PropellerPure

/// Названо по тому, ради чего мета вообще снимается: «какие из этих встреч —
/// один и тот же еженедельный синк?». Ответ даёт не похожесть названий, а
/// идентификатор серии, и он обязан дожить до документа в целости.
final class CalendarMetaTests: XCTestCase {

    private func meta(
        eventID: String = "EV-1",
        seriesID: String? = "SERIES-1",
        title: String = "Вк Музыка дейлик",
        calendarName: String? = "Работа",
        organizer: String? = "Левон",
        attendees: [String] = ["Аня", "Максим"],
        conferenceURL: String? = "https://zoom.us/j/123",
        start: Date? = Date(timeIntervalSince1970: 1_784_000_000),
        end: Date? = nil,
        isRecurring: Bool = true
    ) -> CalendarMeta {
        CalendarMeta(
            eventID: eventID,
            seriesID: seriesID,
            title: title,
            calendarName: calendarName,
            organizer: organizer,
            attendees: attendees,
            conferenceURL: conferenceURL,
            start: start,
            end: end,
            isRecurring: isRecurring
        )
    }

    // MARK: - Что доезжает до документа

    func testTheSeriesKeyReachesBothDocumentFormats() {
        let m = meta()
        XCTAssertTrue(m.yamlFrontmatterLines.contains("calendar_series_id: \"SERIES-1\""))
        XCTAssertTrue(m.plainHeaderLines.contains { $0.contains("SERIES-1") })
    }

    /// Простой формат — дефолтный. Если он оставит только красивую половину,
    /// склеивать встречи потом будет нечем.
    func testThePlainFormatKeepsTheIdentifiersNotJustTheProseLine() {
        let lines = meta().plainHeaderLines
        XCTAssertTrue(lines.contains { $0.hasPrefix("**Calendar:**") && $0.contains("Вк Музыка дейлик") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("**Calendar ID:**") && $0.contains("EV-1") })
    }

    func testARecurringEventSaysSoInBothFormats() {
        XCTAssertTrue(meta().yamlFrontmatterLines.contains("calendar_recurring: true"))
        XCTAssertTrue(meta().plainHeaderLines.contains { $0.contains("повторяется") })

        let once = meta(isRecurring: false)
        XCTAssertFalse(once.yamlFrontmatterLines.contains { $0.hasPrefix("calendar_recurring") })
        XCTAssertFalse(once.plainHeaderLines.contains { $0.contains("повторяется") })
    }

    func testTheCallLinkSurvivesBecauseAPermanentRoomIsAnIdentifierToo() {
        XCTAssertTrue(
            meta().yamlFrontmatterLines.contains("calendar_conference_url: \"https://zoom.us/j/123\"")
        )
    }

    func testStartTimeIsWrittenInUTCSoTwoMachinesAgree() {
        let m = meta(start: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(m.yamlFrontmatterLines.contains("calendar_start: \"1970-01-01T00:00:00Z\""))
    }

    // MARK: - Чего в документе быть не должно

    /// Приглашённые приезжают из EventKit как есть: с пробелами по краям, с
    /// повторами (человек в двух списках рассылки) и с пустыми строками.
    func testTheInviteeListIsTrimmedDedupedAndKeptInOrder() {
        let m = meta(attendees: ["  Аня ", "Максим", "Аня", "", "   "])
        XCTAssertEqual(m.attendees, ["Аня", "Максим"])
        XCTAssertTrue(m.yamlFrontmatterLines.contains("calendar_attendees: [\"Аня\", \"Максим\"]"))
    }

    /// Кавычка в названии встречи не должна закрывать значение раньше времени —
    /// front matter после этого не парсится ничем.
    func testAQuoteInTheEventTitleCannotBreakTheFrontMatter() {
        let m = meta(title: "Разбор \"Пропеллера\"")
        let line = m.yamlFrontmatterLines.first { $0.hasPrefix("calendar_title:") }
        XCTAssertEqual(line, "calendar_title: \"Разбор 'Пропеллера'\"")
    }

    /// Пустой ключ хуже отсутствующего: он выглядит как ответ.
    func testMissingFieldsAreOmittedRatherThanWrittenEmpty() {
        let m = CalendarMeta(eventID: "EV-2", title: "Созвон")
        let yaml = m.yamlFrontmatterLines
        XCTAssertEqual(yaml, ["calendar_event_id: \"EV-2\"", "calendar_title: \"Созвон\""])
        XCTAssertFalse(m.plainHeaderLines.contains { $0.hasPrefix("**Invited:**") })
        XCTAssertFalse(m.plainHeaderLines.contains { $0.hasPrefix("**Call:**") })
    }

    /// Встреча без календаря — обычный случай (звонок с телефона, спонтанный
    /// созвон). В документе от этого не должно появиться ни одной лишней строки.
    func testAMeetingWithNoCalendarMatchAddsNothingToTheDocument() {
        let empty = CalendarMeta(eventID: "  ")
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.yamlFrontmatterLines.isEmpty)
        XCTAssertTrue(empty.plainHeaderLines.isEmpty)
    }

    // MARK: - Хранение

    func testItSurvivesARoundTripThroughTheArchiveOnDisk() throws {
        let original = meta(end: Date(timeIntervalSince1970: 1_784_003_600))
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(CalendarMeta.self, from: data)
        XCTAssertEqual(restored, original)
    }
}
