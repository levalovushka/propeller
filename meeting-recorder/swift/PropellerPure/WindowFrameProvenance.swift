import CoreGraphics
import Foundation

/// Who set the size of the main window — the app, or the person.
///
/// The app writes a frame exactly once per install, when there is nothing saved
/// to open at: `placeCentered`. Everything else in that key is somebody dragging
/// or zooming. Telling the two apart used to be attempted by width — two numbers
/// we had once shipped as the opening size were refused on load — and a person
/// who dragged their window to exactly one of them lost it on every reopen,
/// forever, with nothing on screen to explain why. A width cannot say who wrote
/// it; only a record of what we wrote can.
///
/// The rule lives here because it is string parsing and two comparisons, and the
/// window code it serves is in an executable target no test can reach.
public enum WindowFrameProvenance {

    /// `NSWindow` writes its frames as `"x y w h …"` — origin and size, in that
    /// order, space separated. Anything else is not a frame we can reason about,
    /// and the safe answer to that is «leave it alone».
    public static func size(of descriptor: String) -> CGSize? {
        let parts = descriptor.split(separator: " ")
        guard parts.count >= 4,
              let width = Double(parts[2]), let height = Double(parts[3]),
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Which of the two saved frames should the window open at?
    ///
    /// There are two keys for one window: ours (`NSWindow Frame PropellerMain`)
    /// and the one SwiftUI made (`main-AppWindow-1`). Ours was read first, on
    /// the assumption that it is the maintained one. **Measured 2026-08-20, it
    /// is not:** across one resize the SwiftUI key tracked the drag live
    /// (797 → 884 → 879 pt) while ours never moved off the frame it was last
    /// written with. So preferring ours meant opening at a size nobody had
    /// chosen since the day that key was last written, which is exactly the
    /// complaint — «растянул, вышел, открылось дефолтным».
    ///
    /// The rule therefore is *freshness by disagreement*: if the two keys
    /// disagree, the one AppKit keeps current wins. They agree in the ordinary
    /// case, and then it does not matter which is returned.
    ///
    /// This does not make the write side correct — our key still needs to be
    /// maintained, or the fallback is load-bearing forever. It makes the read
    /// side stop discarding a size the person set.
    public static func preferredFrame(own: String?, swiftUI: String?) -> String? {
        switch (own, swiftUI) {
        case (nil, nil): return nil
        case (let own?, nil): return own
        case (nil, let swiftUI?): return swiftUI
        case (let own?, let swiftUI?):
            guard let ownSize = size(of: own), let swiftUISize = size(of: swiftUI) else {
                return size(of: own) == nil ? swiftUI : own
            }
            let sameSize = abs(ownSize.width - swiftUISize.width) < 1
                && abs(ownSize.height - swiftUISize.height) < 1
            return sameSize ? own : swiftUI
        }
    }

    /// May this saved frame be replaced by the current opening size?
    ///
    /// Only when both hold: it is character-for-character the frame we placed
    /// ourselves, **and** that frame is no longer the size we would open at. The
    /// first drag makes the saved string differ from the marker, and from then
    /// on the answer is always no — whatever the window measures.
    ///
    /// `expected` is the frame we would place now, in frame terms rather than
    /// content terms; the caller computes it, because turning a content size
    /// into a frame needs the window.
    public static func isStalePlacement(
        saved: String,
        placedByUs: String?,
        expected: CGSize,
        tolerance: CGFloat = 1
    ) -> Bool {
        guard let placedByUs, placedByUs == saved else { return false }
        guard let size = size(of: saved) else { return false }
        return abs(size.width - expected.width) >= tolerance
            || abs(size.height - expected.height) >= tolerance
    }
}
