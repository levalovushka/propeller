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
}
