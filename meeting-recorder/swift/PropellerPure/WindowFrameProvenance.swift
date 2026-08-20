import CoreGraphics
import Foundation

/// Which saved frame the main window should open at.
///
/// There are two keys in defaults for one window: the one SwiftUI's
/// `WindowGroup` maintains (`NSWindow Frame main-AppWindow-1`) and one the app
/// tried to keep for itself (`NSWindow Frame PropellerMain`). **Measured
/// 2026-08-21, and this is the whole reason this type exists:** across one drag
/// the window went 813 → 1014 pt, `saveFrame(usingName: "PropellerMain")` was
/// called about twenty-five times, and the value under our own key never
/// changed once. After the quit, SwiftUI's key held `1014 760` and ours still
/// held `797 760`.
///
/// So our key is dead on write — `setFrameAutosaveName` returns `true` but the
/// window's real persistence belongs to SwiftUI — and reading it in preference
/// closed a loop: open at the dead key's stale size, let SwiftUI save what was
/// applied, and the size the person chose is gone. That is what «растянул,
/// вышел, открылось дефолтным» was.
///
/// The rule is therefore short: trust the key that is demonstrably maintained,
/// and keep ours only for an install old enough to have nothing else.
public enum WindowFrameProvenance {

    /// `NSWindow` writes frames as `"x y w h …"` — origin then size, space
    /// separated. Anything else is not a frame, and the safe answer to that is
    /// «leave the window alone», because refusing to restore is the one outcome
    /// a person notices.
    public static func size(of descriptor: String) -> CGSize? {
        let parts = descriptor.split(separator: " ")
        guard parts.count >= 4,
              let width = Double(parts[2]), let height = Double(parts[3]),
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The frame to open at, or `nil` when there is nothing saved and the window
    /// should be placed at its opening size.
    ///
    /// `maintained` is the key the system keeps current (SwiftUI's); `legacy` is
    /// ours. The maintained one wins whenever it is readable — not when it
    /// disagrees, *whenever it exists* — because ours is not updated at all and
    /// «they agree» only ever means our stale value has already been copied over
    /// the live one.
    public static func preferredFrame(maintained: String?, legacy: String?) -> String? {
        if let maintained, size(of: maintained) != nil { return maintained }
        if let legacy, size(of: legacy) != nil { return legacy }
        return nil
    }
}
