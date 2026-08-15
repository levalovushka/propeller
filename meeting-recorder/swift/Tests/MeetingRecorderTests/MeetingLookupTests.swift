import XCTest
import PropellerPure

/// Отбор встреч для Клода. Проверяется тем, что человек увидит в разговоре:
/// «такой встречи не было» — худший из возможных ответов, и почти всегда он
/// означает не пустой архив, а слишком строгое сито.
final class MeetingLookupTests: XCTestCase {

    private func date(_ day: Int, _ hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = day
        components.hour = hour
        return Calendar.current.date(from: components)!
    }

    private func card(
        _ id: String,
        day: Int,
        title: String = "Встреча",
        topics: [String] = [],
        tags: [String] = [],
        people: [String] = [],
        body: String = ""
    ) -> MeetingCard {
        MeetingCard(
            id: id, date: date(day), title: title, durationSeconds: 600,
            topics: topics, tags: tags, people: people,
            dateLabel: "\(day) августа 2026", bodies: body.isEmpty ? [] : [body]
        )
    }

    private var archive: [MeetingCard] {
        [
            card("c", day: 14, title: "Стратегия студии", topics: ["найм"],
                 people: ["Левон", "Speaker S1"], body: "обсудили переход к консалтингу"),
            card("b", day: 10, title: "Синк по релизу", tags: ["планирование"],
                 people: ["Левон", "Костя"], body: "релиз в пятницу, вебхуки чинит Костя"),
            card("a", day: 3, title: "Один на один", people: ["Марина"],
                 body: "нагрузка и отпуск"),
        ]
    }

    // MARK: - Пустой запрос

    func testWithoutAQuestionTheNewestMeetingsComeBack() {
        let found = MeetingLookup.run(cards: archive, filter: .init())
        XCTAssertEqual(found.map(\.card.id), ["c", "b", "a"])
        XCTAssertNil(found[0].snippet)
    }

    func testTheAnswerIsCappedSoTheArchiveCannotFloodTheConversation() {
        let many = (1...40).map { card("m\($0)", day: 1 + $0 % 28) }
        XCTAssertEqual(MeetingLookup.run(cards: many, filter: .init()).count, MeetingLookup.defaultLimit)
    }

    // MARK: - Даты

    func testBothEndsOfTheDateRangeAreInclusive() {
        let filter = MeetingLookup.Filter(
            from: MeetingLookup.day("2026-08-10"),
            to: MeetingLookup.endOfDay("2026-08-14")
        )
        XCTAssertEqual(MeetingLookup.run(cards: archive, filter: filter).map(\.card.id), ["c", "b"])
    }

    /// Встреча в 23:50 последнего дня диапазона — внутри него. Верхняя граница,
    /// взятая как полночь, теряла бы весь последний день.
    func testTheLastDayIsWholeNotUntilMidnight() {
        let late = [card("late", day: 14, title: "Поздняя")].map {
            MeetingCard(id: $0.id, date: date(14, 23), title: $0.title, durationSeconds: 0,
                        topics: [], tags: [], people: [], dateLabel: $0.dateLabel, bodies: [])
        }
        let filter = MeetingLookup.Filter(to: MeetingLookup.endOfDay("2026-08-14"))
        XCTAssertEqual(MeetingLookup.run(cards: late, filter: filter).count, 1)
    }

    func testAnUnreadableDateIsRefusedRatherThanGuessed() {
        XCTAssertNil(MeetingLookup.day("вчера"))
        XCTAssertNil(MeetingLookup.day("2026-13-01"))
        XCTAssertNil(MeetingLookup.day(nil))
    }

    // MARK: - Люди

    func testAskingAboutAPersonIgnoresCaseAndShortForms() {
        for asked in ["Костя", "костя", "кост"] {
            let filter = MeetingLookup.Filter(people: [asked])
            XCTAssertEqual(MeetingLookup.run(cards: archive, filter: filter).map(\.card.id), ["b"], asked)
        }
    }

    func testNamingSeveralPeopleMeansAnyOfThem() {
        let filter = MeetingLookup.Filter(people: ["Марина", "Костя"])
        XCTAssertEqual(MeetingLookup.run(cards: archive, filter: filter).map(\.card.id), ["b", "a"])
    }

    // MARK: - Слова

    func testTheMatchedLineComesBackWithTheMeeting() {
        let filter = MeetingLookup.Filter(query: "вебхуки")
        let found = MeetingLookup.run(cards: archive, filter: filter)
        XCTAssertEqual(found.map(\.card.id), ["b"])
        XCTAssertEqual(found[0].snippet?.match, "вебхуки")
    }

    /// Темы и теги — часть того, по чему ищут: человек спрашивает «что было по
    /// найму», а слово стоит в темах, а не в тексте.
    func testTopicsAndTagsAreSearchedToo() {
        XCTAssertEqual(
            MeetingLookup.run(cards: archive, filter: .init(query: "найм")).map(\.card.id), ["c"]
        )
        XCTAssertEqual(
            MeetingLookup.run(cards: archive, filter: .init(query: "планирование")).map(\.card.id), ["b"]
        )
    }

    func testDatesAndPeopleNarrowTheSearchTogether() {
        let filter = MeetingLookup.Filter(
            query: "релиз",
            from: MeetingLookup.day("2026-08-12"),
            people: []
        )
        XCTAssertTrue(MeetingLookup.run(cards: archive, filter: filter).isEmpty)
    }

    // MARK: - Решения и вопросы

    private var digests: [(card: MeetingCard, digest: RecapDigest)] {
        [
            (archive[0], RecapDigest.parse("""
                ## Решения
                - Берём четырёх человек в штат к концу года.
                - Овертайм только в исключительных случаях.
                ## Открытые вопросы
                - Кто вычитывает результат.
                """)),
            (archive[1], RecapDigest.parse("""
                ## Решения
                - [22:06] Релиз переносим на пятницу.
                """)),
        ]
    }

    func testDecisionsCarryTheirMeetingAndTimecode() {
        let items = MeetingLookup.harvest(section: RecapDigest.decisionsTitle, from: digests)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.last?.meetingID, "b")
        XCTAssertEqual(items.last?.timecode, "22:06")
        XCTAssertNil(items.first?.timecode)
    }

    /// Тема ищется и в пункте, и во встрече: спросив «что решили по найму»,
    /// человек имеет в виду и решение со словом «найм», и любое решение
    /// встречи, которая вся про найм.
    func testATopicMatchesTheMeetingAndNotOnlyTheWording() {
        let items = MeetingLookup.harvest(section: RecapDigest.decisionsTitle, from: digests, topic: "найм")
        XCTAssertEqual(items.map(\.text).count, 2)
        XCTAssertTrue(items.allSatisfy { $0.meetingID == "c" })
    }

    func testATopicNobodyDiscussedComesBackEmptyRatherThanWithEverything() {
        let items = MeetingLookup.harvest(section: RecapDigest.decisionsTitle, from: digests, topic: "бюджет")
        XCTAssertTrue(items.isEmpty)
    }

    func testOpenQuestionsAreTheirOwnSection() {
        let items = MeetingLookup.harvest(section: RecapDigest.openQuestionsTitle, from: digests)
        XCTAssertEqual(items.map(\.text), ["Кто вычитывает результат."])
    }

    func testTheHarvestIsCappedToo() {
        let long = RecapDigest.parse("## Решения\n" + (1...80).map { "- пункт \($0)" }.joined(separator: "\n"))
        let items = MeetingLookup.harvest(section: RecapDigest.decisionsTitle, from: [(archive[0], long)])
        XCTAssertEqual(items.count, MeetingLookup.harvestLimit)
    }
}
