import XCTest
@testable import PropellerPure

/// One stamp, two shapes, and the trap between them. Until 2026-08-20 the
/// arithmetic lived in six places and the pattern in two, so these tests exist
/// to keep the two shapes deliberate instead of accidental.
final class TimecodeTests: XCTestCase {

    // MARK: - What a person reads

    func testTheHourHandAppearsOnlyWhenThereIsOne() {
        XCTAssertEqual(Timecode.text(0), "00:00")
        XCTAssertEqual(Timecode.text(62), "01:02")
        XCTAssertEqual(Timecode.text(3599), "59:59")
        XCTAssertEqual(Timecode.text(3600), "1:00:00")
        XCTAssertEqual(Timecode.text(3723), "1:02:03")
    }

    /// A clock that has not started cannot read `00:-5`, which is what the
    /// unclamped arithmetic returned for a negative offset.
    func testTimeBeforeZeroIsZero() {
        XCTAssertEqual(Timecode.text(-5), "00:00")
        XCTAssertEqual(Timecode.text(.nan), "00:00")
        XCTAssertEqual(Timecode.text(.infinity), "00:00")
    }

    // MARK: - What the transcript file carries

    /// The saved transcript counts minutes without a ceiling. Every file
    /// already on disk is in this shape, so the ninety-minute mark reads
    /// `90:12` and not `1:30:12`.
    func testTheTranscriptCountsMinutesWithoutACeiling() {
        XCTAssertEqual(Timecode.minutesSeconds(5412), "90:12")
        XCTAssertEqual(Timecode.minutesSeconds(62), "01:02")
        XCTAssertEqual(Timecode.minutesSeconds(-1), "00:00")
    }

    // MARK: - Back to seconds

    func testBothShapesReadBackToTheSameSecond() {
        XCTAssertEqual(Timecode.seconds("01:02"), 62)
        XCTAssertEqual(Timecode.seconds("1:02:03"), 3723)
        XCTAssertEqual(Timecode.seconds("90:12"), 5412)
    }

    func testWhatIsNotAStampSaysSo() {
        XCTAssertNil(Timecode.seconds("мусор"))
        XCTAssertNil(Timecode.seconds("12"))
        XCTAssertNil(Timecode.seconds("1:2:3:4"))
        XCTAssertNil(Timecode.seconds("-1:00"))
    }

    func testEitherShapeSurvivesTheRoundTrip() {
        for seconds in [0.0, 59, 60, 3599, 3600, 5412, 36_000] {
            XCTAssertEqual(Timecode.seconds(Timecode.text(seconds)), seconds)
            XCTAssertEqual(Timecode.seconds(Timecode.minutesSeconds(seconds)), seconds)
        }
    }

    // MARK: - The mine

    /// The block head is one pattern for the writer and both readers. When it
    /// was two, one accepted a third component and the other did not — so a
    /// stamp past the first hour kept its words and silently lost its speaker
    /// and its time.
    func testASpeakerKeepsTheirNamePastTheFirstHour() {
        let transcript = """
        [Иван] [90:12]
        первый час позади

        [Мария] [1:30:20]
        и здесь тоже
        """
        let turns = TranscriptPresentation.turns(parsing: transcript, duration: 6000)
        XCTAssertEqual(turns.map(\.speaker), ["Иван", "Мария"])
        XCTAssertEqual(turns.map(\.timestamp), ["1:30:12", "1:30:20"])
    }
}
