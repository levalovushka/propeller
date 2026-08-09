import XCTest
import PropellerPure

/// # Заметка стоит там, где её написали
///
/// Названо тем, что человек видит: он пишет заметку в момент, когда прозвучало
/// важное, и потом ищет её рядом с этим важным, а не в конце ленты.
final class NotePlacementTests: XCTestCase {

    private func feed(_ turns: [Double], _ notes: [Double?]) -> [NotePlacement.Item] {
        NotePlacement.interleave(turnStarts: turns, noteOffsets: notes)
    }

    func testANoteStandsBetweenTheRemarksItWasWrittenBetween() {
        XCTAssertEqual(
            feed([0, 10, 20], [12]),
            [.turn(index: 0), .turn(index: 1), .note(index: 0), .turn(index: 2)]
        )
    }

    /// Заметку пишут про то, что только что услышали. На одной секунде с
    /// репликой она — отклик на неё, а не подпись к ней сверху.
    func testANoteOnTheSameSecondAnswersTheRemarkRatherThanAnnouncesIt() {
        XCTAssertEqual(
            feed([0, 10], [10]),
            [.turn(index: 0), .turn(index: 1), .note(index: 0)]
        )
    }

    func testANoteWrittenBeforeAnybodySpokeComesFirst() {
        XCTAssertEqual(feed([5], [0]), [.note(index: 0), .turn(index: 0)])
    }

    func testNotesWrittenInTheSilenceAtTheEndStayAtTheEnd() {
        XCTAssertEqual(
            feed([0], [30, 40]),
            [.turn(index: 0), .note(index: 0), .note(index: 1)]
        )
    }

    /// Заметка без времени — дописанная после встречи. В расшифровке ей места
    /// нет: любая секунда для неё выдумана. Она живёт в саммари.
    func testANoteWithNoTimeIsNotInTheTranscriptAtAll() {
        XCTAssertEqual(
            feed([0, 10], [nil, 5, nil]),
            [.turn(index: 0), .note(index: 1), .turn(index: 1)]
        )
    }

    /// Встреча, у которой расшифровки нет вовсе (микрофонный путь, тишина),
    /// всё равно показывает то, что человек в ней написал.
    func testAMeetingWithNoRemarksStillShowsItsNotes() {
        XCTAssertEqual(feed([], [10, 0]), [.note(index: 1), .note(index: 0)])
    }

    func testNothingInNothingOut() {
        XCTAssertTrue(feed([], []).isEmpty)
        XCTAssertTrue(feed([], [nil]).isEmpty)
    }

    /// Две заметки на одной секунде остаются в том порядке, в каком их писали:
    /// вторая мысль идёт после первой, а не вместо неё.
    func testTwoNotesOnTheSameSecondKeepTheOrderTheyWereWrittenIn() {
        XCTAssertEqual(
            feed([0], [7, 7]),
            [.turn(index: 0), .note(index: 0), .note(index: 1)]
        )
    }

    /// Время старой заметки прочитано из её текста и может оказаться каким
    /// угодно — лента от этого не должна перепутаться.
    func testANoteWhoseTimeCameOutOfOrderStillLandsOnItsSecond() {
        XCTAssertEqual(
            feed([0, 10, 20], [25, 5]),
            [.turn(index: 0), .note(index: 1), .turn(index: 1), .turn(index: 2), .note(index: 0)]
        )
    }

    /// Порядок реплик — не наше дело: колонка уже решила, что за чем, и второе
    /// решение здесь разошлось бы с ней там, где люди перебивают друг друга.
    func testTheOrderOfRemarksIsTakenAsGiven() {
        XCTAssertEqual(
            feed([30, 10], []),
            [.turn(index: 0), .turn(index: 1)]
        )
    }

    /// Каждая реплика и каждая заметка со временем попадает в ленту ровно один
    /// раз — сколько бы их ни было и как бы они ни были расставлены.
    func testEveryRemarkAndEveryPlacedNoteAppearsExactlyOnce() {
        var seed: UInt64 = 20260809
        func random(_ upper: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(upper))
        }
        for _ in 0..<200 {
            let turns = (0..<random(6)).map { _ in Double(random(60)) }.sorted()
            let notes: [Double?] = (0..<random(6)).map { _ in
                random(4) == 0 ? nil : Double(random(60))
            }
            let items = feed(turns, notes)
            XCTAssertEqual(
                items.filter { if case .turn = $0 { return true } else { return false } }.count,
                turns.count
            )
            XCTAssertEqual(
                items.filter { if case .note = $0 { return true } else { return false } }.count,
                notes.compactMap { $0 }.count
            )
            XCTAssertEqual(Set(items).count, items.count, "Ничего не удвоилось.")
        }
    }
}
