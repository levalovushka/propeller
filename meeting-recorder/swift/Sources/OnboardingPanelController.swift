import AppKit
import PropellerUI
import SwiftUI

/// Borderless-looking plate that can still become key — required for TextField /
/// Toggle. Pure `.borderless` panels often refuse keyboard focus
/// (see SO 63089253); NoteOverlay uses the same `canBecomeKey` override.
private final class OnboardingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Dedicated onboarding plate (AppKit `NSPanel`), not a resized `WindowGroup`.
///
/// Glass fill matches the main window: SwiftUI `GlassBackground` → `Tokens.Glass`.
@MainActor
final class OnboardingPanelController {
    static let shared = OnboardingPanelController()

    private(set) var panel: NSPanel?
    private weak var state: AppState?

    private let contentSize = NSSize(width: Tokens.Setup.width, height: Tokens.Setup.height)

    func show(state: AppState) {
        self.state = state
        if panel == nil {
            panel = makePanel(state: state)
        }
        guard let panel else { return }
        panel.setContentSize(contentSize)
        panel.center()
        NSApp.setActivationPolicy(.regular)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        state = nil
        stopWatchingForReturn()
    }

    /// Step aside for a system window we just asked macOS to open.
    ///
    /// The plate is a floating panel, so it sits above ordinary windows: System
    /// Settings opened *behind* it and, from the user's side, tapping "grant"
    /// appeared to do nothing. Dropping to the normal level lets the usual
    /// window ordering apply; the level is restored as soon as the user comes
    /// back to us, so the plate still floats over our own windows.
    func yieldToSystemWindow() {
        guard let panel else { return }
        panel.level = .normal
        watchForReturn()
        // Hand activation over explicitly — `NSWorkspace.open` alone leaves us
        // frontmost, and System Settings then opens without focus.
        NSApp.deactivate()
    }

    private var returnObserver: NSObjectProtocol?

    private func watchForReturn() {
        guard returnObserver == nil else { return }
        returnObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel?.level = .floating
                self.stopWatchingForReturn()
            }
        }
    }

    private func stopWatchingForReturn() {
        if let returnObserver {
            NotificationCenter.default.removeObserver(returnObserver)
        }
        returnObserver = nil
    }

    private func makePanel(state: AppState) -> NSPanel {
        let content = OnboardingContainer(state: state)
            .frame(width: contentSize.width, height: contentSize.height)
            .background(GlassBackground(cornerRadius: Tokens.Setup.radius))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Setup.radius, style: .continuous))
            .ignoresSafeArea()

        // `.titled` + hidden transparent titlebar (not `.borderless`): AppKit
        // delivers key events to TextField/Toggle.
        //
        // `.closable` is here for ⌘W, not for a disc. The plate has no titlebar
        // row any more — the mark opens its content column instead, on the very
        // margin the discs would sit on — so nothing is drawn, but the screen
        // must still not be a trap: closing it leaves Propeller in the menu bar
        // with setup still owed, and it comes back next launch with whatever
        // grants were given in the meantime already ticked.
        //
        // Worth knowing if the discs ever come back: `standardWindowButton`
        // returns **nil** for a button the style mask does not claim — measured
        // on this panel's previous mask, `[.titled, .fullSizeContentView]`, which
        // hands back nil for the close button. Showing them without claiming
        // them is a no-op that reads as working code.
        let panel = OnboardingPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Welcome"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none

        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = Tokens.Setup.radius
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting

        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView?.wantsLayer = true

        hideTrafficLights(on: panel)

        return panel
    }

    /// No discs on the plate.
    ///
    /// The comps put the mark where they would go, on the content column's own
    /// top-left margin (Figma 91:934) — two things cannot have that corner. The
    /// way out is ⌘W, which `.closable` gives without drawing anything.
    private func hideTrafficLights(on panel: NSPanel) {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(type)?.isHidden = true
        }
    }
}
