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

    /// The frame that leaves exactly `contentWidth` points of content.
    ///
    /// The counterpart of `frame(revealing:)`, and only ever narrower: the
    /// notes were put away, so the room they took goes back. The window keeps
    /// its left edge — growth went rightwards, so the giving back has to come
    /// off the same edge, or hiding a column would walk the window across the
    /// screen. Never grows: a window already narrower than the target is one
    /// whose notes were a button to begin with.
    public static func frame(
        hiding contentWidth: CGFloat,
        window: CGRect,
        chromeWidth: CGFloat = 0,
        visible: CGRect
    ) -> CGRect {
        let wanted = contentWidth + chromeWidth
        guard wanted < window.width else { return window }
        return CGRect(x: window.minX, y: window.minY, width: wanted, height: window.height)
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

    /// Content width that folds the notes into their button and leaves the left
    /// column exactly where it is.
    ///
    /// The mirror of `contentWidth(revealingNotesBeside:)`, and deliberately not
    /// «minus the notes' width»: the button takes `collapsedSlot` of the room
    /// the column had, so giving back all of it would slide the summary
    /// leftwards by 52 pt. What the eye is watching is the text, not the edge.
    public static func contentWidth(
        hidingNotes split: PaneSplit,
        sidebar: CGFloat,
        collapsedSlot: CGFloat
    ) -> CGFloat {
        sidebar + split.left + collapsedSlot
    }

    /// Left / notes widths for a pane of `width`.
    ///
    /// `pinnedLeft` is set for the duration of a reveal: the left column stays
    /// put while the window grows and the notes take whatever appears on the
    /// right. Without it, every intermediate width below `openAt` still looks
    /// collapsed, so the summary widens and then snaps in. It holds the same
    /// column still through a hide, where the window is travelling the other
    /// way and the summary would otherwise narrow by 52 pt on the way down.
    ///
    /// `hidden` is the one thing width cannot say: the notes were *put away*.
    /// Room is not the question there — a 1200 pt pane has plenty and the
    /// column still has to go — so it is asked first and answered before any
    /// arithmetic.
    public static func paneSplit(
        width pane: CGFloat,
        pinnedLeft: CGFloat?,
        hidden: Bool = false,
        summaryMin: CGFloat,
        notesMin: CGFloat,
        notesMax: CGFloat,
        collapsedSlot: CGFloat,
        openAt: CGFloat
    ) -> PaneSplit {
        // The pin is on while the window is travelling — in *either* direction.
        // The column is on screen for the whole trip, taking whatever lies to
        // the right of the held column, so a hide is a departure rather than a
        // disappearance: the button cannot arrive before the window has
        // finished moving, because until then there is still a column there.
        if let pinned = pinnedLeft {
            return PaneSplit(left: pinned, notes: max(0, pane - pinned), open: true)
        }
        if hidden {
            return PaneSplit(left: max(0, pane - collapsedSlot), notes: collapsedSlot, open: false)
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

    /// How far along the column is between «сложена в кнопку» and «стоит целиком».
    ///
    /// The window's travel is the clock: a column 52 pt wide has just left the
    /// button and a column at its floor width is fully here. Anything that
    /// should not simply be wiped into view by the moving window edge — the
    /// ink, the last few points of travel — hangs off this.
    ///
    /// It is symmetric on purpose. Hide and reveal are the same journey in
    /// opposite directions, and a departure that faded differently from an
    /// arrival would read as two unrelated animations on one control.
    public static func notesArrival(
        notes: CGFloat,
        collapsedSlot: CGFloat,
        notesMin: CGFloat
    ) -> CGFloat {
        let span = notesMin - collapsedSlot
        guard span > 0 else { return notes > collapsedSlot ? 1 : 0 }
        return min(1, max(0, (notes - collapsedSlot) / span))
    }
}
