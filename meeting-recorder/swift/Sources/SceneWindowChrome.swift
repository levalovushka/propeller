import AppKit
import PropellerUI
import SwiftUI

enum AppWindowRole: String {
    case main
}

@MainActor
enum AppWindowRegistry {
    /// Figma `sidebar` artboard (31:4580) — a 300 pt rail plus an 800 pt pane.
    /// What the window *opens* at.
    static let mainSize = CGSize(width: Tokens.Sidebar.width + 800, height: 640)

    /// The smallest the window may be dragged to — a different question, and
    /// using `mainSize` for both is what pinned the window at its opening width.
    /// The comps go down to a 601 pt pane (`thin`), which is where the notes
    /// collapse; below the pane's own minimum there is nothing left to show.
    static let minSize = CGSize(
        width: Tokens.Sidebar.width + Tokens.Window.contentPaneMinWidth,
        height: 480
    )

    static func mainWindow() -> NSWindow? {
        let onboarding = OnboardingPanelController.shared.panel
        if let tagged = NSApp.windows.first(where: { $0.identifier?.rawValue == AppWindowRole.main.rawValue }) {
            return tagged
        }
        return NSApp.windows.first { window in
            window !== onboarding && window.frame.width >= 600
        }
    }

    /// Hide without destroying — used while the onboarding panel is up.
    static func hideMain() {
        guard let window = mainWindow() else { return }
        window.alphaValue = 0
        window.orderOut(nil)
    }

    /// Show the main window at its final size, centered. Never grows from the
    /// onboarding plate — that morph is what felt like a jerk.
    static func showMain(centered: Bool = true) {
        NSApp.setActivationPolicy(.regular)
        guard let window = mainWindow() else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        window.alphaValue = 1
        if centered {
            placeCentered(window, contentSize: mainSize)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func placeCentered(_ window: NSWindow, contentSize: CGSize) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        window.setContentSize(contentSize)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        frame.origin = NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        )
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minX < visible.minX { frame.origin.x = visible.minX }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        window.setFrame(frame, display: true, animate: false)
    }
}

/// Tags the main window, keeps its host transparent, and nudges traffic lights
/// to the Figma Meetings chrome slot (640:1863).
struct SceneWindowChrome: NSViewRepresentable {
    var role: AppWindowRole = .main
    var startHidden: Bool = false

    func makeNSView(context: Context) -> NSView {
        let view = ChromeHostView()
        view.onApply = { [role, startHidden] window in
            Self.configure(window, role: role, startHidden: startHidden)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? ChromeHostView else { return }
        view.onApply = { [role, startHidden] window in
            Self.configure(window, role: role, startHidden: startHidden)
        }
        DispatchQueue.main.async { Self.configure(view.window, role: role, startHidden: startHidden) }
    }

    private static func configure(_ window: NSWindow?, role: AppWindowRole, startHidden: Bool) {
        guard let window else { return }
        window.identifier = NSUserInterfaceItemIdentifier(role.rawValue)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        positionTrafficLights(on: window)
        if startHidden, window.isVisible || window.alphaValue > 0 {
            window.alphaValue = 0
            window.orderOut(nil)
        }
    }

    /// Figma 31:4584 — discs Ø12 at (24,18) / (44,18) / (64,18) from window
    /// top-leading, i.e. centred on the rail header's 48 pt row. They sit four
    /// points higher than they did on the old 56 pt bar; the header shrank.
    private static func positionTrafficLights(on window: NSWindow) {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        guard let close = window.standardWindowButton(.closeButton),
              let container = close.superview
        else { return }

        for (index, type) in types.enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            let origin = SidebarTrafficLightLayout.origin(
                index: index,
                containerHeight: container.bounds.height,
                buttonHeight: button.bounds.height
            )
            button.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
        }
    }
}

/// Re-applies chrome whenever the host moves between windows or lays out.
private final class ChromeHostView: NSView {
    var onApply: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onApply?(window)
    }

    override func layout() {
        super.layout()
        onApply?(window)
    }
}
