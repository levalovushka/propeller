import XCTest
@testable import PropellerPure

/// The rule that decides whether a meeting still needs a name. It used to live
/// in three places, twice as an inline pair of `hasPrefix` calls, and nothing
/// tied the wording the app writes to the wording the app looks for.
final class MeetingTitleTests: XCTestCase {

    /// The invariant that was unenforceable while the rule was copied: whatever
    /// the writer produces, the reader must recognise. Break the prefix in one
    /// place and this fails instead of the app quietly never titling anything.
    func testWhateverTheAppNamesAMeetingItKnowsItNamedIt() {
        for stamp in ["20.08.2026, 11:08", "8/20/26, 11:08 AM", ""] {
            XCTAssertTrue(MeetingTitle.isPlaceholder(MeetingTitle.placeholder(stamp: stamp)))
        }
    }

    /// A person's archive outlives a wording decision, so titles written before
    /// the interface spoke Russian are still recognised as ours.
    func testTitlesFromTheEnglishDaysAreStillOurs() {
        XCTAssertTrue(MeetingTitle.isPlaceholder("Recording 8/20/26, 11:08 AM"))
    }

    func testANameSomebodyChoseIsNotAPlaceholder() {
        XCTAssertFalse(MeetingTitle.isPlaceholder("Синк по найму"))
        XCTAssertFalse(MeetingTitle.isPlaceholder(""))
        XCTAssertFalse(MeetingTitle.isPlaceholder("Перезапись демо"))
    }

    /// The prefix on its own proves nothing — somebody can rename a meeting to
    /// «Запись про бюджет». Callers owe the manual-rename latch a look, and this
    /// test exists so that fact is written down where the rule lives.
    func testAHumanNameCanStillLookLikeOurs() {
        XCTAssertTrue(MeetingTitle.isPlaceholder("Запись про бюджет"))
    }
}
