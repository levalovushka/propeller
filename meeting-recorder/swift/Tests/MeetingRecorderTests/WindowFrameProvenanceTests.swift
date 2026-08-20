import XCTest
@testable import PropellerPure

/// The window opens at the size its owner left it. This file exists because the
/// previous rule guessed provenance from width, and a person who dragged their
/// window to one of two particular numbers lost that size on every reopen.
final class WindowFrameProvenanceTests: XCTestCase {

    private let opening = CGSize(width: 920, height: 760)

    // MARK: - A size somebody chose

    /// The whole point: whatever the person set comes back, even when it happens
    /// to be a number the app itself once opened at.
    func testASizeTheOwnerChoseIsNeverReplaced() {
        for saved in [
            "100 100 1100 760 0 0 1440 900",   // an old opening width, dragged to by hand
            "100 100 1020 760 0 0 1440 900",   // the other one
            "0 0 920 760 0 0 1440 900",        // exactly today's opening size
            "40 40 1600 1200 0 0 2560 1440",
        ] {
            XCTAssertFalse(
                WindowFrameProvenance.isStalePlacement(
                    saved: saved, placedByUs: "0 0 1100 760 0 0 1440 900", expected: opening
                ),
                saved
            )
        }
    }

    /// No marker at all — an install from before provenance was recorded. Its
    /// frame is somebody's until proven otherwise.
    func testWithoutAMarkerTheSavedFrameStands() {
        XCTAssertFalse(
            WindowFrameProvenance.isStalePlacement(
                saved: "100 100 1100 760 0 0 1440 900", placedByUs: nil, expected: opening
            )
        )
    }

    // MARK: - A size the app put there

    /// A frame we placed ourselves, at a size we no longer open at, may go.
    func testOurOwnStalePlacementIsReplaced() {
        let ours = "260 70 1100 760 0 0 1440 900"
        XCTAssertTrue(
            WindowFrameProvenance.isStalePlacement(
                saved: ours, placedByUs: ours, expected: opening
            )
        )
    }

    /// Placed by us and still the opening size: nothing to supersede.
    func testOurOwnCurrentPlacementStays() {
        let ours = "260 70 920 760 0 0 1440 900"
        XCTAssertFalse(
            WindowFrameProvenance.isStalePlacement(
                saved: ours, placedByUs: ours, expected: opening
            )
        )
    }

    /// One drag is enough to make the frame the person's — the marker no longer
    /// matches, so the size is theirs from then on even if they drag it back to
    /// what we had placed.
    func testOneDragMakesTheFrameTheirsForever() {
        let placed = "260 70 1100 760 0 0 1440 900"
        let dragged = "300 90 1100 760 0 0 1440 900"   // same size, moved
        XCTAssertFalse(
            WindowFrameProvenance.isStalePlacement(
                saved: dragged, placedByUs: placed, expected: opening
            )
        )
    }

    // MARK: - Parsing

    func testAFrameStringYieldsItsSize() {
        XCTAssertEqual(
            WindowFrameProvenance.size(of: "260 70 920 760 0 0 1440 900"),
            CGSize(width: 920, height: 760)
        )
    }

    /// Anything we cannot read is left alone rather than guessed at: refusing to
    /// restore a frame is the one outcome a person notices.
    func testWhatCannotBeReadIsNotAFrame() {
        for junk in ["", "920 760", "a b c d", "0 0 0 0"] {
            XCTAssertNil(WindowFrameProvenance.size(of: junk), junk)
            XCTAssertFalse(
                WindowFrameProvenance.isStalePlacement(
                    saved: junk, placedByUs: junk, expected: opening
                ),
                junk
            )
        }
    }

    /// Sub-pixel drift from AppKit's own rounding is not a different size.
    func testASubPixelDifferenceIsTheSameSize() {
        let ours = "260 70 920.4 760.2 0 0 1440 900"
        XCTAssertFalse(
            WindowFrameProvenance.isStalePlacement(
                saved: ours, placedByUs: ours, expected: opening
            )
        )
    }
}
