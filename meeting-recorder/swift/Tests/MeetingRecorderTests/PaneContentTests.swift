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

    /// The composer is at the top of the column, so what you just wrote has to
    /// appear under it — not at the foot of everything written before.
    func testTheColumnShowsTheNewestNoteFirst() {
        let stored = [
            MeetingNoteRecord(id: "1", text: "Первая"),
            MeetingNoteRecord(id: "2", text: "Вторая"),
            MeetingNoteRecord(id: "3", text: "Третья"),
        ]
        XCTAssertEqual(
            MeetingNotes.newestFirst(stored).map(\.text),
            ["Третья", "Вторая", "Первая"]
        )
    }

    /// And the file does not turn around with it: the blob is poured into the
    /// «Заметки» block of a transcript, and a transcript reads forward.
    func testStorageStaysInTheOrderItWasWritten() {
        let stored = [
            MeetingNoteRecord(id: "1", text: "Первая"),
            MeetingNoteRecord(id: "2", text: "Вторая"),
        ]
        _ = MeetingNotes.newestFirst(stored)
        XCTAssertEqual(MeetingNotes.blob(from: stored), "Первая\n\nВторая")
    }
}

