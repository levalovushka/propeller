import XCTest
@testable import PropellerPure

/// Which saved frame the window opens at. The rule is short because the
/// measurement behind it is blunt: our own key is not written at all, so
/// preferring it means opening at a size from whenever it last was.
final class WindowFrameProvenanceTests: XCTestCase {

    /// The case that cost the owner his window size twice: the maintained key
    /// holds what he set, ours holds something older, and ours used to win.
    func testTheMaintainedKeyWins() {
        let maintained = "204 33 1014 760 0 0 1512 949"
        let legacy = "1833 -10 797 760 1512 -60 1920 1050"
        XCTAssertEqual(
            WindowFrameProvenance.preferredFrame(maintained: maintained, legacy: legacy),
            maintained
        )
    }

    /// Not «when they disagree» — whenever the maintained key exists. Agreement
    /// only ever means our stale value has already been copied over the live
    /// one, which is the loop that ate the size in the first place.
    func testTheMaintainedKeyWinsEvenWhenTheyAgree() {
        let same = "204 33 797 760 0 0 1512 949"
        XCTAssertEqual(
            WindowFrameProvenance.preferredFrame(maintained: same, legacy: same),
            same
        )
    }

    /// An install old enough to have only our key still opens where it was left.
    func testTheLegacyKeyIsUsedWhenThereIsNothingElse() {
        let legacy = "100 100 1100 800 0 0 1920 1050"
        XCTAssertEqual(
            WindowFrameProvenance.preferredFrame(maintained: nil, legacy: legacy),
            legacy
        )
    }

    /// Nothing saved: the caller places the window at its opening size.
    func testNothingSavedIsNoFrame() {
        XCTAssertNil(WindowFrameProvenance.preferredFrame(maintained: nil, legacy: nil))
    }

    /// A key that cannot be read must not win by being unreadable — refusing to
    /// restore is the one outcome a person notices.
    func testUnreadableLosesToReadable() {
        let good = "0 0 920 760 0 0 1440 900"
        XCTAssertEqual(
            WindowFrameProvenance.preferredFrame(maintained: "junk", legacy: good), good
        )
        XCTAssertEqual(
            WindowFrameProvenance.preferredFrame(maintained: good, legacy: "junk"), good
        )
        XCTAssertNil(WindowFrameProvenance.preferredFrame(maintained: "junk", legacy: ""))
    }

    // MARK: - Parsing

    func testAFrameStringYieldsItsSize() {
        XCTAssertEqual(
            WindowFrameProvenance.size(of: "260 70 920 760 0 0 1440 900"),
            CGSize(width: 920, height: 760)
        )
    }

    /// AppKit writes a trailing space; the archive is full of them.
    func testATrailingSpaceIsStillAFrame() {
        XCTAssertEqual(
            WindowFrameProvenance.size(of: "1833 -10 797 760 1512 -60 1920 1050 "),
            CGSize(width: 797, height: 760)
        )
    }

    func testWhatCannotBeReadIsNotAFrame() {
        for junk in ["", "920 760", "a b c d", "0 0 0 0"] {
            XCTAssertNil(WindowFrameProvenance.size(of: junk), junk)
        }
    }
}
