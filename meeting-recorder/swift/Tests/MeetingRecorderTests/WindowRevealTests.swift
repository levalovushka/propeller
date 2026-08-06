import XCTest
import PropellerPure
import PropellerUI

/// # Pressing the notes button in a narrow window
///
/// The notes fold into a button when the pane cannot hold them, and the button
/// answers by growing the window. Named after what a person sees, because the
/// bug is "I clicked the notes and nothing happened" — which is what a window
/// against the right edge of the screen used to do — and "the summary ballooned
/// then snapped back", which is what growing to a fixed threshold used to do.
final class WindowRevealTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testANarrowWindowGrowsUntilTheNotesFit() {
        let window = CGRect(x: 100, y: 100, width: 900, height: 640)
        let grown = WindowReveal.frame(revealing: 1060, window: window, visible: screen)
        XCTAssertEqual(grown.width, 1060)
        XCTAssertEqual(grown.minX, 100, "The window grows to the right; nothing asked it to move.")
        XCTAssertEqual(grown.height, 640)
    }

    func testAWindowAgainstTheRightEdgePullsItsLeftEdgeBack() {
        // 340 pt of room on the right, 160 short of what the notes need.
        let window = CGRect(x: 1100, y: 100, width: 340, height: 640)
        let grown = WindowReveal.frame(revealing: 500, window: window, visible: screen)
        XCTAssertEqual(grown.width, 500)
        XCTAssertEqual(grown.maxX, screen.maxX, "It has nowhere to grow but leftwards.")
    }

    func testItNeverGrowsPastTheScreen() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 640)
        let grown = WindowReveal.frame(revealing: 2000, window: window, visible: screen)
        XCTAssertEqual(grown.width, screen.width)
        XCTAssertEqual(grown.minX, screen.minX)
    }

    func testAWindowThatAlreadyFitsIsLeftAlone() {
        let window = CGRect(x: 40, y: 60, width: 1200, height: 700)
        XCTAssertEqual(
            WindowReveal.frame(revealing: 1060, window: window, visible: screen),
            window,
            "The button is «покажи заметки», not «поставь окно вот так»."
        )
    }

    func testTitlebarChromeIsCountedIn() {
        let window = CGRect(x: 100, y: 100, width: 900, height: 640)
        let grown = WindowReveal.frame(
            revealing: 1060, window: window, chromeWidth: 16, visible: screen
        )
        XCTAssertEqual(grown.width, 1076, "1060 pt of content still has to be 1060 pt of content.")
    }

    /// The click keeps the summary's width and grows only for the notes —
    /// not to a fixed «notes just fit» threshold that would reflow the text.
    func testRevealKeepsTheLeftColumnWidth() {
        let sidebar = Tokens.Sidebar.width
        let pane: CGFloat = 620
        let content = sidebar + pane
        let leftBefore = pane - Tokens.Pane.notesCollapsedSide

        let target = WindowReveal.contentWidth(
            revealingNotesBeside: content,
            sidebar: sidebar,
            collapsedSlot: Tokens.Pane.notesCollapsedSide,
            notesWidth: Tokens.Pane.notesMaxWidth,
            minimumPane: Tokens.Pane.notesCollapseBelow
        )
        let targetPane = target - sidebar
        let settled = WindowReveal.paneSplit(
            width: targetPane,
            pinnedLeft: nil,
            summaryMin: Tokens.Pane.summaryMinWidth,
            notesMin: Tokens.Pane.notesMinWidth,
            notesMax: Tokens.Pane.notesMaxWidth,
            collapsedSlot: Tokens.Pane.notesCollapsedSide,
            openAt: Tokens.Pane.notesCollapseBelow
        )
        XCTAssertTrue(settled.open)
        XCTAssertEqual(settled.left, leftBefore, accuracy: 0.5)
        XCTAssertEqual(settled.notes, Tokens.Pane.notesMaxWidth, accuracy: 0.5)
    }

    /// Mid-animation widths stay pinned: the summary must not inflate while the
    /// window is still below the ordinary open threshold.
    func testPinnedSplitHoldsTheLeftColumnWhileTheWindowGrows() {
        let leftBefore: CGFloat = 568
        let mid = WindowReveal.paneSplit(
            width: 700,
            pinnedLeft: leftBefore,
            summaryMin: Tokens.Pane.summaryMinWidth,
            notesMin: Tokens.Pane.notesMinWidth,
            notesMax: Tokens.Pane.notesMaxWidth,
            collapsedSlot: Tokens.Pane.notesCollapsedSide,
            openAt: Tokens.Pane.notesCollapseBelow
        )
        XCTAssertTrue(mid.open)
        XCTAssertEqual(mid.left, leftBefore)
        XCTAssertEqual(mid.notes, 700 - leftBefore, accuracy: 0.5)

        let unpinned = WindowReveal.paneSplit(
            width: 700,
            pinnedLeft: nil,
            summaryMin: Tokens.Pane.summaryMinWidth,
            notesMin: Tokens.Pane.notesMinWidth,
            notesMax: Tokens.Pane.notesMaxWidth,
            collapsedSlot: Tokens.Pane.notesCollapsedSide,
            openAt: Tokens.Pane.notesCollapseBelow
        )
        XCTAssertFalse(unpinned.open, "Without the pin, 700 is still a button.")
    }

    func testTheDefaultPaneKeepsNotesCollapsed() {
        // First open is the screenshot with the pencil button, not the split.
        // Crossing `notesCollapseBelow` would ship with notes already open.
        XCTAssertLessThan(
            Tokens.Window.defaultPaneWidth,
            Tokens.Pane.notesCollapseBelow
        )
    }

    // MARK: - Ordinary adaptivity (pin is nil — every path but the button click)

    /// The pin is a reveal-only latch. With it off, the split is the same
    /// flex it has always been: collapse below the threshold, notes between
    /// floor and ceiling above it, leftover to the summary.
    func testUnpinnedSplitCollapsesBelowTheThreshold() {
        let thin = split(width: Tokens.Window.defaultPaneWidth)
        XCTAssertFalse(thin.open)
        XCTAssertEqual(thin.notes, Tokens.Pane.notesCollapsedSide)
        XCTAssertEqual(
            thin.left,
            Tokens.Window.defaultPaneWidth - Tokens.Pane.notesCollapsedSide,
            accuracy: 0.5
        )

        let justUnder = split(width: Tokens.Pane.notesCollapseBelow - 1)
        XCTAssertFalse(justUnder.open)
    }

    func testUnpinnedSplitOpensAtTheThreshold() {
        let at = split(width: Tokens.Pane.notesCollapseBelow)
        XCTAssertTrue(at.open)
        XCTAssertEqual(at.notes, Tokens.Pane.notesMinWidth, accuracy: 0.5)
        XCTAssertEqual(at.left, Tokens.Pane.summaryMinWidth, accuracy: 0.5)
    }

    func testUnpinnedSplitCapsNotesAndGivesTheRestToTheSummary() {
        // Wide pane: notes stop at their ceiling, summary takes everything else
        // and centres its measure in it — the 1200 pt gallery board.
        let wide = split(width: 1200)
        XCTAssertTrue(wide.open)
        XCTAssertEqual(wide.notes, Tokens.Pane.notesMaxWidth, accuracy: 0.5)
        XCTAssertEqual(wide.left, 1200 - Tokens.Pane.notesMaxWidth, accuracy: 0.5)
    }

    func testUnpinnedSplitLetsNotesGrowBetweenFloorAndCeiling() {
        // Just above threshold the leftover past summaryMin is still under the
        // notes' ceiling, so notes take it rather than jumping to max.
        let pane = Tokens.Pane.summaryMinWidth + 260
        let mid = split(width: pane)
        XCTAssertTrue(mid.open)
        XCTAssertEqual(mid.notes, 260, accuracy: 0.5)
        XCTAssertEqual(mid.left, Tokens.Pane.summaryMinWidth, accuracy: 0.5)
    }

    private func split(width: CGFloat, pinned: CGFloat? = nil) -> WindowReveal.PaneSplit {
        WindowReveal.paneSplit(
            width: width,
            pinnedLeft: pinned,
            summaryMin: Tokens.Pane.summaryMinWidth,
            notesMin: Tokens.Pane.notesMinWidth,
            notesMax: Tokens.Pane.notesMaxWidth,
            collapsedSlot: Tokens.Pane.notesCollapsedSide,
            openAt: Tokens.Pane.notesCollapseBelow
        )
    }
}
