import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// # Making room for a column that collapsed
///
/// A column that folds into a button when the pane is too narrow has to have
/// somewhere to unfold to, and the only thing that can give it room is the
/// window. So pressing the button is a request for a frame, and the frame is
/// decided here rather than in AppKit — a screen edge is exactly the case that
/// is never reached by hand and always reached by a user.
public enum WindowReveal {

    /// How the pane divides between the meeting and the notes.
    public struct PaneSplit: Equatable, Sendable {
        public var left: CGFloat
        public var notes: CGFloat
        public var open: Bool

        public init(left: CGFloat, notes: CGFloat, open: Bool) {
            self.left = left
            self.notes = notes
            self.open = open
        }
    }

    /// The frame that leaves at least `contentWidth` points of content.
    ///
    /// Grows to the right while the screen allows and pulls the left edge back
    /// when it does not, so a window parked against the right edge still opens
    /// its notes. Never shrinks — a window already wide enough keeps the frame
    /// it has, because the button is «покажи», not «поставь окно вот так».
    ///
    /// - Parameters:
    ///   - contentWidth: what the content needs, in points.
    ///   - window: the window's current frame, in screen coordinates.
    ///   - chromeWidth: frame width minus content width — zero for a
    ///     full-size-content window, and not assumed to be.
    ///   - visible: the screen's visible frame, menu bar and Dock excluded.
    public static func frame(
        revealing contentWidth: CGFloat,
        window: CGRect,
        chromeWidth: CGFloat = 0,
        visible: CGRect
    ) -> CGRect {
        let wanted = contentWidth + chromeWidth
        guard wanted > window.width else { return window }
        // The screen is the ceiling: a window wider than its screen loses the
        // traffic lights off one edge, which is worse than narrow notes.
        let width = min(wanted, visible.width)
        var x = window.minX
        if x + width > visible.maxX { x = visible.maxX - width }
        if x < visible.minX { x = visible.minX }
        return CGRect(x: x, y: window.minY, width: width, height: window.height)
    }

    /// Content width that opens the notes beside the column that was already
    /// showing.
    ///
    /// The left column keeps the width it had while the notes were a button;
    /// the window grows to the right by the notes' width. Growing to a fixed
    /// «notes just fit» threshold instead made the summary stretch with the
    /// window and then snap back when the notes appeared.
    public static func contentWidth(
        revealingNotesBeside current: CGFloat,
        sidebar: CGFloat,
        collapsedSlot: CGFloat,
        notesWidth: CGFloat,
        minimumPane: CGFloat
    ) -> CGFloat {
        let pane = current - sidebar
        let left = max(0, pane - collapsedSlot)
        return sidebar + max(left + notesWidth, minimumPane)
    }

    /// Left / notes widths for a pane of `width`.
    ///
    /// `pinnedLeft` is set for the duration of a reveal: the left column stays
    /// put while the window grows and the notes take whatever appears on the
    /// right. Without it, every intermediate width below `openAt` still looks
    /// collapsed, so the summary widens and then snaps in.
    public static func paneSplit(
        width pane: CGFloat,
        pinnedLeft: CGFloat?,
        summaryMin: CGFloat,
        notesMin: CGFloat,
        notesMax: CGFloat,
        collapsedSlot: CGFloat,
        openAt: CGFloat
    ) -> PaneSplit {
        if let pinned = pinnedLeft {
            return PaneSplit(left: pinned, notes: max(0, pane - pinned), open: true)
        }
        guard pane >= openAt else {
            return PaneSplit(
                left: max(0, pane - collapsedSlot),
                notes: collapsedSlot,
                open: false
            )
        }
        let notes = min(notesMax, max(notesMin, pane - summaryMin))
        return PaneSplit(left: pane - notes, notes: notes, open: true)
    }
}
