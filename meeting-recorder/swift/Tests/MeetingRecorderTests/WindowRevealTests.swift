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
        let settled = split(width: targetPane)
        XCTAssertTrue(settled.open)
        XCTAssertEqual(settled.left, leftBefore, accuracy: 0.5)
        XCTAssertEqual(settled.notes, Tokens.Pane.notesMaxWidth, accuracy: 0.5)
    }

    /// Mid-animation widths stay pinned: the summary must not inflate while the
    /// window is still below the ordinary open threshold.
    func testPinnedSplitHoldsTheLeftColumnWhileTheWindowGrows() {
        let leftBefore: CGFloat = 568
        let trip = WindowReveal.NotesTravel(left: leftBefore, notes: 280)
        let mid = split(width: 700, travel: trip)
        XCTAssertTrue(mid.open)
        XCTAssertEqual(mid.left, leftBefore)
        XCTAssertEqual(mid.notes, 700 - leftBefore, accuracy: 0.5)

        let unpinned = split(width: 700)
        XCTAssertFalse(unpinned.open, "Without the travel, 700 is still a button.")
    }

    func testTheDefaultPaneKeepsNotesCollapsed() {
        // First open is the screenshot with the pencil button, not the split.
        // Crossing `notesCollapseBelow` would ship with notes already open.
        XCTAssertLessThan(
            Tokens.Window.defaultPaneWidth,
            Tokens.Pane.notesCollapseBelow
        )
    }

    // MARK: - Putting the notes away

    /// The whole point of the button: what you are reading does not move. Only
    /// the right edge of the window does.
    func testHidingTheNotesLeavesTheSummaryExactlyWhereItWas() {
        let sidebar = Tokens.Sidebar.width
        let pane: CGFloat = 1200
        let open = split(width: pane)
        XCTAssertTrue(open.open)

        let target = WindowReveal.contentWidth(
            hidingNotes: open,
            sidebar: sidebar,
            collapsedSlot: Tokens.Pane.notesCollapsedSide
        )
        let settled = split(width: target - sidebar, hidden: true)
        XCTAssertFalse(settled.open)
        XCTAssertEqual(
            settled.left, open.left, accuracy: 0.5,
            "Саммари стоит там же — сузился только правый край окна."
        )
    }

    /// Hide, then press the button that brings them back: the summary is the
    /// width it started at. A round trip that drifts by 52 pt walks the text
    /// sideways every time you use the control.
    func testHideThenRevealIsARoundTrip() {
        let sidebar = Tokens.Sidebar.width
        let before = split(width: 1200)

        let hiddenContent = WindowReveal.contentWidth(
            hidingNotes: before,
            sidebar: sidebar,
            collapsedSlot: Tokens.Pane.notesCollapsedSide
        )
        let backContent = WindowReveal.contentWidth(
            revealingNotesBeside: hiddenContent,
            sidebar: sidebar,
            collapsedSlot: Tokens.Pane.notesCollapsedSide,
            notesWidth: Tokens.Pane.notesMaxWidth,
            minimumPane: Tokens.Pane.notesCollapseBelow
        )
        let after = split(width: backContent - sidebar)
        XCTAssertTrue(after.open)
        XCTAssertEqual(after.left, before.left, accuracy: 0.5)
        XCTAssertEqual(after.notes, before.notes, accuracy: 0.5)
    }

    /// Room is not the question. A pane with 1200 pt of it still has to put the
    /// notes away when it is asked to — that is what width alone cannot say.
    func testHiddenNotesStayHiddenHoweverWideThePaneIs() {
        let wide = split(width: 1200, hidden: true)
        XCTAssertFalse(wide.open)
        XCTAssertEqual(wide.notes, Tokens.Pane.notesCollapsedSide)
        XCTAssertEqual(wide.left, 1200 - Tokens.Pane.notesCollapsedSide, accuracy: 0.5)
    }

    /// The pin holds through a hide too — the window is travelling the other
    /// way, and without it the summary narrows by 52 pt on the way down and
    /// comes back at the end.
    ///
    /// And the column is still *there* while it travels: it leaves with the
    /// window rather than vanishing under it, which is the only way the button
    /// that replaces it can arrive after the movement instead of before.
    func testTheColumnIsStillOnScreenWhileTheWindowNarrows() {
        let left: CGFloat = 920
        let trip = WindowReveal.NotesTravel(left: left, notes: 280)
        let mid = split(width: 1100, travel: trip, hidden: true)
        XCTAssertTrue(mid.open, "Уходит, а не исчезает.")
        XCTAssertEqual(mid.left, left)
        XCTAssertEqual(mid.notes, 180, accuracy: 0.5)

        // Доехали: шпильку сняли — вот теперь кнопка.
        let settled = split(width: left + Tokens.Pane.notesCollapsedSide, hidden: true)
        XCTAssertFalse(settled.open)
        XCTAssertEqual(settled.left, left, accuracy: 0.5)
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

    private func split(
        width: CGFloat, travel: WindowReveal.NotesTravel? = nil, hidden: Bool = false
    ) -> WindowReveal.PaneSplit {
        WindowReveal.paneSplit(
            width: width,
            travel: travel,
            hidden: hidden,
            summaryMin: Tokens.Pane.summaryMinWidth,
            notesMin: Tokens.Pane.notesMinWidth,
            notesMax: Tokens.Pane.notesMaxWidth,
            collapsedSlot: Tokens.Pane.notesCollapsedSide,
            openAt: Tokens.Pane.notesCollapseBelow
        )
    }
}
