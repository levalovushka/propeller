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

    private let contentSize = NSSize(width: Tokens.Card.width, height: Tokens.Card.height)

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
            .environment(\.onboardingHostProvidesGlass, true)
            .frame(width: contentSize.width, height: contentSize.height)
            .background(GlassBackground(cornerRadius: Tokens.Card.radius))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Card.radius, style: .continuous))
            .ignoresSafeArea()

        // `.titled` + hidden transparent titlebar (not `.borderless`): AppKit
        // delivers key events to TextField/Toggle. Hide traffic lights.
        let panel = OnboardingPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Welcome"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none

        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = Tokens.Card.radius
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

        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        return panel
    }
}
