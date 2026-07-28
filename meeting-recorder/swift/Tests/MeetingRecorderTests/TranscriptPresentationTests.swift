import XCTest
@testable import PropellerPure

/// Every karaoke defect found by hand so far lived in this logic. Each one now
/// has a test named after what the user actually saw.
final class TranscriptPresentationTests: XCTestCase {

    private typealias Sut = TranscriptPresentation

    private func segment(_ index: Int, _ start: Double, _ end: Double, _ speaker: String, _ text: String) -> PersistedSegment {
        PersistedSegment(index: index, startTime: start, endTime: end, text: text, speaker: speaker)
    }

    // MARK: - Turns from segments

    func testConsecutiveSegmentsFromOneSpeakerBecomeOneTurnWithManyPhrases() {
        let turns = Sut.turns(from: [
            segment(0, 1.0, 3.0, "Левон", "Раз, два, три."),
            segment(1, 3.5, 6.0, "Левон", "Это тестовая встреча."),
            segment(2, 7.0, 9.0, "Левон", "И если получится."),
        ])
        XCTAssertEqual(turns.count, 1)
        // The bug the user reported as "highlights the whole thing at once":
        // one phrase per turn means nothing to highlight within it.
        XCTAssertEqual(turns[0].phrases.count, 3)
        XCTAssertEqual(turns[0].startSeconds, 1.0)
        XCTAssertEqual(turns[0].endSeconds, 9.0)
    }

    func testASpeakerChangeStartsANewTurn() {
        let turns = Sut.turns(from: [
            segment(0, 1.0, 3.0, "Левон", "Привет."),
            segment(1, 3.2, 5.0, "Speaker 1", "Привет."),
        ])
        XCTAssertEqual(turns.map(\.speaker), ["Левон", "Speaker 1"])
    }

    func testALongPauseBreaksATurnEvenForTheSameSpeaker() {
        let turns = Sut.turns(from: [
            segment(0, 1.0, 3.0, "Левон", "Начали."),
            segment(1, 3.0 + Sut.turnGapSeconds + 0.1, 12.0, "Левон", "Продолжаю через паузу."),
        ])
        XCTAssertEqual(turns.count, 2, "a gap longer than \(Sut.turnGapSeconds)s reads as a new remark")
    }

    func testEmptySegmentsAreSkippedNotRendered() {
        // Emptied segments are how an edit collapses a remark — they must not
        // show up as blank phrases.
        let turns = Sut.turns(from: [
            segment(0, 1.0, 3.0, "Левон", "Текст."),
            segment(1, 3.1, 4.0, "Левон", "   "),
        ])
        XCTAssertEqual(turns.first?.phrases.count, 1)
    }

    func testAZeroLengthSegmentStillGetsAUsableRange() {
        // Real data has these: `[12.72–12.72] хорошо`. A zero-width phrase can
        // never be "current", so karaoke would skip over it.
        let turns = Sut.turns(from: [segment(0, 12.72, 12.72, "Левон", "хорошо")])
        XCTAssertGreaterThan(turns[0].phrases[0].endSeconds, turns[0].phrases[0].startSeconds)
    }

    // MARK: - Turns parsed from text

    func testParsesTheCurrentTranscriptFormat() {
        let text = """
        [Левон] [00:02]
        Это запись небольшой встречи.

        [Speaker 1] [00:14]
        Согласен, давай продолжим.
        """
        let turns = Sut.turns(parsing: text, duration: 30)
        XCTAssertEqual(turns.map(\.speaker), ["Левон", "Speaker 1"])
        XCTAssertEqual(turns[0].startSeconds, 2)
        XCTAssertEqual(turns[1].startSeconds, 14)
        XCTAssertEqual(turns[0].timestamp, "00:02")
    }

    func testStillParsesTheTwoOlderFormatsOnDisk() {
        let old = """
        **[00:05] Левон:** Старый формат с жирным.

        [01:10] Speaker 1: Совсем старый формат.
        """
        let turns = Sut.turns(parsing: old, duration: 120)
        XCTAssertEqual(turns.map(\.speaker), ["Левон", "Speaker 1"])
        XCTAssertEqual(turns[0].phrases[0].text, "Старый формат с жирным.")
        XCTAssertEqual(turns[1].startSeconds, 70)
    }

    func testStripsASRControlTokens() {
        let turns = Sut.turns(parsing: "[00:01] Левон: <|spk1|>Текст без мусора.", duration: 10)
        XCTAssertEqual(turns[0].phrases[0].text, "Текст без мусора.")
    }

    func testAnUnparseableLineKeepsItsWordsRatherThanVanishing() {
        let turns = Sut.turns(parsing: "Просто строка без разметки", duration: 10)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].phrases[0].text, "Просто строка без разметки")
    }

    /// Losing the segment snapshot is what made a whole remark one phrase —
    /// this pins the cost so it can't be mistaken for a rendering bug again.
    func testParsedTextGivesOnePhrasePerRemarkUnlikeSegments() {
        let text = "[Левон] [00:02]\nДлинная реплика из нескольких предложений. Вот второе."
        XCTAssertEqual(Sut.turns(parsing: text, duration: 30)[0].phrases.count, 1)
    }

    // MARK: - Words

    func testWordsCarryTheTimingOfTheirOwnPhrase() {
        let turns = Sut.turns(from: [
            segment(0, 1.0, 3.0, "Левон", "первая фраза"),
            segment(1, 3.5, 6.0, "Левон", "вторая фраза"),
        ])
        let words = Sut.words(in: turns[0])
        XCTAssertEqual(words.map(\.text), ["первая", "фраза", "вторая", "фраза"])
        // Clicking "вторая" must seek to 3.5, not to the start of the remark.
        XCTAssertEqual(words[2].startSeconds, 3.5)
        XCTAssertEqual(words[0].startSeconds, 1.0)
    }

    func testWordIdsAreUniqueWithinATurn() {
        let turns = Sut.turns(from: [segment(0, 0, 5, "Левон", "одно и то же и то же")])
        let ids = Sut.words(in: turns[0]).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate ids make ForEach drop views")
    }

    // MARK: - Speakers and timestamps

    func testSpeakersAreListedInFirstAppearanceOrder() {
        let turns = Sut.turns(from: [
            segment(0, 1, 2, "Б", "раз"),
            segment(1, 3, 4, "А", "два"),
            segment(2, 20, 21, "Б", "три"),
        ])
        XCTAssertEqual(Sut.speakers(in: turns), ["Б", "А"])
    }

    func testTimestampRoundTrip() {
        XCTAssertEqual(Sut.formatTimestamp(62), "01:02")
        XCTAssertEqual(Sut.formatTimestamp(3723), "1:02:03")
        XCTAssertEqual(Sut.parseTimestamp("01:02"), 62)
        XCTAssertEqual(Sut.parseTimestamp("1:02:03"), 3723)
        XCTAssertEqual(Sut.parseTimestamp("мусор"), 0)
    }
}
