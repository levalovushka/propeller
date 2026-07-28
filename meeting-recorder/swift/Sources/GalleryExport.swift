#if GALLERY
import AppKit
import PropellerPure
import SwiftUI

/// # Exporting the gallery
///
/// Renders every screen in `UIStateCatalog` to a PNG and quits:
///
/// ```
/// ./build.sh --gallery
/// /Applications/Propeller.app/Contents/MacOS/MeetingRecorder --gallery-export ~/Desktop/states
/// ```
///
/// # Why an exporter rather than screenshots by hand
///
/// Forty-odd screens photographed one at a time means forty chances to catch a
/// window mid-animation, at the wrong size, or to miss one and not notice. Here
/// every screen is drawn in catalogue order and named by the catalogue's own id,
/// so a re-export replaces frames one-for-one instead of leaving a second pile
/// to reconcile with the first.
///
/// # Why it captures a real window rather than using ImageRenderer
///
/// `ImageRenderer` was the obvious choice and it does not work here: it draws
/// SwiftUI only. Anything AppKit-backed — `SettingsLink`, `TextEditor`,
/// `Toggle`, the `NSVisualEffectView` behind the glass — comes out as the yellow
/// "unsupported" placeholder, which covered entire meeting screens. So each view
/// is hosted in a real window, shown far offscreen, and captured through
/// `CGWindowListCreateImage`, i.e. the same compositing path the user sees.
/// Native controls and materials come out right because nothing is being
/// simulated.
///
/// Screen Recording permission is required for that capture; the app already
/// holds it for system-audio capture.
///
/// # Safety
///
/// Nothing here writes to the archive: meetings are fabricated, poses are
/// ephemeral, and the process exits when the last frame is on disk.
enum GalleryExport {

    static let launchFlag = "--gallery-export"

    static var requestedDirectory: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: launchFlag), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
    }

    /// Far enough offscreen that the flash never lands on a visible display.
    private static let offscreenOrigin = NSPoint(x: -8000, y: -8000)

    @MainActor
    static func exportAll(state: AppState, to directory: URL) async -> [URL] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []

        for id in UIStateCatalog.allScreenIDs {
            GalleryScreenFactory.pose(id: id, state: state)
            if let url = await capture(id: id, state: state, into: directory) {
                written.append(url)
            }
        }
        NSLog("[GalleryExport] wrote \(written.count)/\(UIStateCatalog.allScreenIDs.count) screens to \(directory.path)")
        return written
    }

    @MainActor
    private static func capture(id: String, state: AppState, into directory: URL) async -> URL? {
        let hosting = NSHostingView(
            rootView: GalleryScreenFactory.view(id: id, state: state)
                .environmentObject(state)
        )
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 2 || size.height < 2 { size = NSSize(width: 900, height: 640) }

        let window = NSWindow(
            contentRect: NSRect(origin: offscreenOrigin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        // One runloop turn plus a beat: materials and AppKit controls need a
        // real display pass before the compositor has anything to hand back.
        try? await Task.sleep(nanoseconds: 250_000_000)

        let windowID = CGWindowID(window.windowNumber)
        guard windowID != 0,
              let image = CGWindowListCreateImage(
                .null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]
              ) else {
            NSLog("[GalleryExport] \(id): window capture returned nothing")
            return nil
        }

        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = directory.appendingPathComponent("\(id).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            NSLog("[GalleryExport] \(id): \(error.localizedDescription)")
            return nil
        }
    }
}
#endif
