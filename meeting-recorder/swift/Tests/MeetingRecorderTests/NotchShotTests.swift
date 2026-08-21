import XCTest
import SwiftUI
import AppKit
import PropellerUI
import PropellerPure

/// A tool, not a test — same idea as `SettingsShotTests`: renders the notch surface
/// onto a fake desktop so the silhouette can be looked at without starting a
/// real recording. Skipped unless `NOTCH_SHOT` names a path.
final class NotchShotTests: XCTestCase {

    @MainActor
    func testShoot() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["NOTCH_SHOT"] == nil,
            "NOTCH_SHOT is not set"
        )
        let output = ProcessInfo.processInfo.environment["NOTCH_SHOT"]!
        let composing = ProcessInfo.processInfo.environment["NOTCH_SHOT_COMPOSING"] != nil
        let stage: NotchGeometry.Stage = composing ? .composing : .resting

        // 14″ MacBook Pro, half scale across so the plate is not lost on the strip.
        let screen = try XCTUnwrap(NotchGeometry.screen(
            left: 0, width: 1512, top: 982, safeAreaTop: 32,
            auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5
        ))
        let draft = ProcessInfo.processInfo.environment["NOTCH_SHOT_TEXT"] ?? ""
        let size = CGSize(width: 760, height: 220)

        let root = ZStack(alignment: .top) {
            // Wallpaper stand-in: the plate has to read against something.
            LinearGradient(colors: [Color(red: 0.35, green: 0.30, blue: 0.42),
                                    Color(red: 0.16, green: 0.14, blue: 0.20)],
                           startPoint: .top, endPoint: .bottom)
            // The hardware cutout itself, drawn as the black it is.
            Rectangle()
                .fill(.black)
                .frame(width: screen.notchWidth, height: screen.notchHeight)
            NotchFace(
                screen: screen,
                stage: stage,
                paused: false,
                noteDraft: draft,
                level: { 0.3 },
                onNote: {}, onCommit: { _ in }, onCancel: {}
            )
        }
        .frame(width: size.width, height: size.height)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output))
    }
}
