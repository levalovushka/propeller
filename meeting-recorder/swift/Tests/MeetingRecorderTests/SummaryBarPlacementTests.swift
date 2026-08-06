import XCTest
import PropellerPure

/// Where the action bar lands — the case that is invisible until it bites:
/// selecting the last words of a line at the right edge of the window, or the
/// last word of the summary against the bottom edge.
final class SummaryBarPlacementTests: XCTestCase {

    private func x(_ anchor: CGFloat, bar: CGFloat, column: CGFloat) -> CGFloat {
        SummaryBarPlacement.x(anchor: anchor, barWidth: bar, columnWidth: column)
    }

    private func y(
        top: CGFloat, bottom: CGFloat, bar: CGFloat, column: CGFloat, gap: CGFloat = 8
    ) -> CGFloat {
        SummaryBarPlacement.y(
            selectionTop: top, selectionBottom: bottom,
            barHeight: bar, columnHeight: column, gap: gap
        )
    }

    func testTheBarStartsUnderTheSelection() {
        XCTAssertEqual(x(120, bar: 346, column: 640), 120)
    }

    func testASelectionAtTheRightEdgeDoesNotPushTheBarOutOfTheWindow() {
        // 520 + 346 = 866, well past the column: the bar stops at 294 so its
        // right edge lands exactly on the column's.
        XCTAssertEqual(x(520, bar: 346, column: 640), 294)
    }

    func testTheBarNeverStartsLeftOfTheColumn() {
        XCTAssertEqual(x(-40, bar: 346, column: 640), 0)
    }

    func testABarWiderThanItsColumnIsPinnedLeftRatherThanCentred() {
        // Cut off on one side, not on two — the block-kind menu is the first
        // thing in the row and the first thing anyone reaches for.
        XCTAssertEqual(x(200, bar: 700, column: 640), 0)
    }

    func testAColumnThatHasNotBeenMeasuredYetDoesNotThrowTheBarLeft() {
        XCTAssertEqual(x(120, bar: 346, column: 0), 0)
    }

    func testTheBarSitsUnderTheSelectionWhenThereIsRoom() {
        // Selection ends at 200; gap 8 → bar top at 208. Column is tall enough.
        XCTAssertEqual(y(top: 180, bottom: 200, bar: 40, column: 400), 208)
    }

    func testTheLastWordFlipsTheBarAboveTheSelection() {
        // Selection ends at 380 in a 400-tall column: 380+8+40 = 428, past the
        // bottom. The bar goes above — top at 180−8−40 = 132.
        XCTAssertEqual(y(top: 180, bottom: 380, bar: 40, column: 400), 132)
    }

    func testASelectionTallerThanTheColumnPinsTheBarToTheBottom() {
        // Nowhere fits: pin to the bottom edge rather than hang below it.
        XCTAssertEqual(y(top: 0, bottom: 390, bar: 40, column: 400), 360)
    }
}
