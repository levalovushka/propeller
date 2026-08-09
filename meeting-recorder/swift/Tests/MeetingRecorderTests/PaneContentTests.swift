import XCTest
import PropellerPure

/// How a decade of single-blob notes becomes a list without losing anything.
///
/// The recap half of this file moved to `SummaryDocumentTests` when the summary
/// stopped being something the pane only displays.
final class PaneContentTests: XCTestCase {

    // MARK: - Notes

    func testALegacyBlobBecomesOneNotePerParagraph() {
        let notes = MeetingNotes.migrate(from: "Первая\n\nВторая строка\nи её продолжение")
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].text, "Первая")
        XCTAssertEqual(notes[1].text, "Вторая строка\nи её продолжение")
    }

    func testASingleNewlineDoesNotSplitANote() {
        // A bulleted note is one note. Splitting every newline turns it into five.
        let notes = MeetingNotes.migrate(from: "план:\n* раз\n* два")
        XCTAssertEqual(notes.count, 1)
    }

    func testMigrationIsStableSoAReReadCannotDuplicate() {
        let blob = "Раз\n\nДва"
        XCTAssertEqual(
            MeetingNotes.migrate(from: blob).map(\.id),
            MeetingNotes.migrate(from: blob).map(\.id)
        )
    }

    func testTheBlobEveryOlderReaderSeesSurvivesARoundTrip() {
        // The overlay, the markdown writer, the recap prompt and search all read
        // `notes`. Records are the new truth; the blob has to stay their exact
        // rendering or an old build opens the archive and sees notes vanish.
        let blob = "Первая\n\nВторая"
        let records = MeetingNotes.migrate(from: blob)
        XCTAssertEqual(MeetingNotes.blob(from: records), blob)
    }

    func testEmptyNotesAreNoNotes() {
        XCTAssertTrue(MeetingNotes.migrate(from: nil).isEmpty)
        XCTAssertTrue(MeetingNotes.migrate(from: "   \n\n  ").isEmpty)
    }

    func testStoredRecordsWinOverTheBlob() {
        let records = [MeetingNoteRecord(id: "a", text: "Новая")]
        XCTAssertEqual(
            MeetingNotes.resolved(items: records, blob: "старое").map(\.text),
            ["Новая"]
        )
        XCTAssertEqual(
            MeetingNotes.resolved(items: nil, blob: "старое").map(\.text),
            ["старое"]
        )
    }
}
