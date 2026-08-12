import XCTest
import Foundation
import PropellerPure

/// Словарь одной встречи. Тесты названы тем, что видно на расшифровке.
final class MeetingHotwordsTests: XCTestCase {

    private func meta(
        title: String = "",
        organizer: String? = nil,
        attendees: [String] = []
    ) -> CalendarMeta {
        CalendarMeta(
            eventID: "evt-1",
            title: title,
            organizer: organizer,
            attendees: attendees
        )
    }

    func testAttendeeGivesBothFullNameAndParts() {
        let terms = MeetingHotwords.terms(for: meta(attendees: ["Радик Ситдиков"]))
        XCTAssertEqual(terms, ["Радик Ситдиков", "Радик", "Ситдиков"])
    }

    /// Ради чего это всё: организатор в EventKit часто приходит адресом.
    func testOrganizerEmailBecomesARussianName() {
        let terms = MeetingHotwords.terms(for: meta(organizer: "radik.sitdikov@vkteam.ru"))
        XCTAssertEqual(terms, ["Радик Ситдиков", "Радик", "Ситдиков"])
    }

    func testTransliterationCoversTheUsualDigraphs() {
        XCTAssertEqual(MeetingHotwords.transliterate("shchedrin"), "щедрин")
        XCTAssertEqual(MeetingHotwords.transliterate("zhukov"), "жуков")
        XCTAssertEqual(MeetingHotwords.transliterate("chernov"), "чернов")
        XCTAssertEqual(MeetingHotwords.transliterate("yulia"), "юлия")
        XCTAssertEqual(MeetingHotwords.transliterate("dmitrii"), "дмитрий")
    }

    /// Неразобранная буква — не имя. Полуслово в подсказках уводит декод.
    func testUnknownLetterDropsTheWholeName() {
        XCTAssertNil(MeetingHotwords.transliterate("mü"))
        XCTAssertNil(MeetingHotwords.nameFromEmail("müller@x.ru"))
    }

    func testServiceAddressesAreNotPeople() {
        XCTAssertNil(MeetingHotwords.nameFromEmail("info@vkteam.ru"))
        XCTAssertNil(MeetingHotwords.nameFromEmail("calendar-invite@vkteam.ru"))
        XCTAssertNil(MeetingHotwords.nameFromEmail("no-reply-service@vkteam.ru"))
        XCTAssertNil(MeetingHotwords.nameFromEmail("levon+work@pragmatica.design"))
        XCTAssertNil(MeetingHotwords.nameFromEmail("k.o@vkteam.ru"))
    }

    /// Односоставный адрес — почти всегда инициалы или сокращение. Сухой прогон
    /// по 26 встречам архива сделал из них «Арсм», «Сенб», «Мкаб» и «Аник».
    func testSingleWordAddressIsNotAName() {
        XCTAssertNil(MeetingHotwords.nameFromEmail("ll@pragmatica.design"))
        XCTAssertNil(MeetingHotwords.nameFromEmail("senb@pragmatica.design"))
        XCTAssertNil(MeetingHotwords.nameFromEmail("hanna@pragmatica.design"))
    }

    /// Инициал вместо имени — не слово, а фамилия рядом с ним — слово.
    func testInitialGivesTheSurnameAlone() {
        XCTAssertEqual(MeetingHotwords.nameFromEmail("i.sarkisova@vk.team"), "Саркисова")
    }

    /// «alexey» разбирается («Алексей»), «dmitry» — нет: по написанию не видно,
    /// «Дмитрий» это или «Дмитрый», а неверная подсказка уводит декод к себе.
    func testAmbiguousYIsRefusedAndTheClearOneIsNot() {
        XCTAssertEqual(MeetingHotwords.transliterate("alexey"), "алексей")
        XCTAssertNil(MeetingHotwords.transliterate("dmitry"))
        XCTAssertNil(MeetingHotwords.nameFromEmail("dmitry.orlov@vkteam.ru"))
    }

    /// Приглашение на сто человек — рассылка: имён из него не берём.
    func testMailingListLeavesOnlyTheOrganiser() {
        let crowd = (1...20).map { "person\($0).surname\($0)@vkteam.ru" }
        let terms = MeetingHotwords.terms(
            for: meta(organizer: "radik.sitdikov@vkteam.ru", attendees: crowd)
        )
        XCTAssertEqual(terms, ["Радик Ситдиков", "Радик", "Ситдиков"])
    }

    /// Общий словарь снял «нид» и «эдит» именно за это: короткое слово поверх
    /// частого обычного. Словарь встречи держит тот же порог.
    func testShortNamesAreDropped() {
        XCTAssertEqual(MeetingHotwords.terms(for: meta(attendees: ["Ян Ли"])), [])
        XCTAssertEqual(
            MeetingHotwords.terms(for: meta(attendees: ["Ян Соколов"])),
            ["Соколов"]
        )
    }

    /// Латиницу модель пишет как придётся; чинит её `TermCanon`, не подсказки.
    func testLatinNamesAreNotBoosted() {
        XCTAssertEqual(MeetingHotwords.terms(for: meta(attendees: ["John Smith"])), [])
    }

    func testTitleGivesProjectNamesAndNotMeetingWords() {
        let terms = MeetingHotwords.terms(for: meta(title: "Дом Пряжи | Оценка КП"))
        XCTAssertEqual(terms, ["Пряжи"])
    }

    func testTitleWordsFollowNames() {
        let terms = MeetingHotwords.terms(
            for: meta(title: "Камуфляж дейлик", attendees: ["Милена Орлова"])
        )
        XCTAssertEqual(terms, ["Милена Орлова", "Милена", "Орлова", "Камуфляж"])
    }

    func testOnePersonIsListedOnce() {
        let terms = MeetingHotwords.terms(
            for: meta(organizer: "Милена Орлова", attendees: ["Милена Орлова", "милена орлова"])
        )
        XCTAssertEqual(terms, ["Милена Орлова", "Милена", "Орлова"])
    }

    func testNoCalendarMeansNoWords() {
        XCTAssertEqual(MeetingHotwords.terms(for: nil), [])
        XCTAssertEqual(MeetingHotwords.terms(for: CalendarMeta(eventID: "")), [])
    }
}
