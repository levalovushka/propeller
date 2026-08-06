import AppKit
import PropellerPure
import PropellerUI
import SwiftUI

enum AppWindowRole: String {
    case main
}

@MainActor
enum AppWindowRegistry {
    /// First-open size: rail + a pane narrow enough that notes stay a button.
    /// After that, the frame the user left is restored (`frameAutosaveName`).
    static let mainSize = CGSize(
        width: Tokens.Sidebar.width + Tokens.Window.defaultPaneWidth,
        height: 640
    )

    /// The smallest the window may be dragged to — a different question, and
    /// using `mainSize` for both is what pinned the window at its opening width.
    /// The comps go down to a 601 pt pane (`thin`), which is where the notes
    /// collapse; below the pane's own minimum there is nothing left to show.
    static let minSize = CGSize(
        width: Tokens.Sidebar.width + Tokens.Window.contentPaneMinWidth,
        height: 480
    )

    /// Our key in UserDefaults (`NSWindow Frame PropellerMain`). SwiftUI also
    /// writes `main-AppWindow-1` for the same window — we read that as a
    /// fallback so a resize the system already remembered is not thrown away.
    static let frameAutosaveName = "PropellerMain"

    /// SwiftUI's WindowGroup id `"main"` persists under this name. Do not
    /// invent a second source of truth without reading it.
    private static let swiftUIFrameKey = "NSWindow Frame main-AppWindow-1"

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
    /// Does not write the frame: an unseen window's size is not a preference.
    static func hideMain() {
        guard let window = mainWindow() else { return }
        window.alphaValue = 0
        window.orderOut(nil)
    }

    /// Show the main window. Restores the user's last frame when there is one;
    /// otherwise opens at `mainSize`, centred. Never grows from the onboarding
    /// plate — that morph is what felt like a jerk.
    ///
    /// Important: do **not** call `placeCentered` when any saved frame exists.
    /// The first persistence attempt restored only `PropellerMain`, which was
    /// never written (SwiftUI saves `main-AppWindow-1`), so every reopen fell
    /// through to the factory size and wiped the drag.
    static func showMain(centered: Bool = true) {
        NSApp.setActivationPolicy(.regular)
        guard let window = mainWindow() else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        window.alphaValue = 1
        rememberFrame(on: window)
        if !applySavedFrame(to: window), centered {
            placeCentered(window, contentSize: mainSize)
            persistFrame(window)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Install autosave and a resize/move watcher. AppKit's autosave alone is
    /// flaky under SwiftUI `WindowGroup` (race on close / `orderOut`); the
    /// watcher writes the same key on every drag so the next `showMain` has
    /// something to read.
    static func rememberFrame(on window: NSWindow) {
        _ = window.setFrameAutosaveName(frameAutosaveName)
        MainWindowFramePersistence.shared.watch(window)
    }

    /// Grow the window until its content is at least `contentWidth` wide — what
    /// a column that collapsed for want of room asks for when it is pressed.
    /// Never shrinks, never leaves the screen; the arithmetic is `WindowReveal`.
    static func widenMain(toContentWidth contentWidth: CGFloat) {
        guard let window = mainWindow(),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        else { return }
        let frame = window.frame
        let chrome = frame.width - window.contentRect(forFrameRect: frame).width
        let target = WindowReveal.frame(
            revealing: contentWidth,
            window: frame,
            chromeWidth: chrome,
            visible: visible
        )
        guard target != frame else { return }
        window.setFrame(target, display: true, animate: true)
        persistFrame(window)
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

    static func persistFrame(_ window: NSWindow) {
        window.saveFrame(usingName: frameAutosaveName)
    }

    /// Our key first, then SwiftUI's — so a frame saved before we owned the
    /// name still opens where the user left it. Factory widths from earlier
    /// defaults are ignored: they were written by `placeCentered`, not by a
    /// person, and would hide every new opening size.
    private static func applySavedFrame(to window: NSWindow) -> Bool {
        let ownKey = "NSWindow Frame \(frameAutosaveName)"
        if let own = UserDefaults.standard.string(forKey: ownKey),
           !isSupersededFactoryFrame(own) {
            window.setFrame(from: own)
            return true
        }
        if let swiftUI = UserDefaults.standard.string(forKey: swiftUIFrameKey),
           !isSupersededFactoryFrame(swiftUI) {
            window.setFrame(from: swiftUI)
            persistFrame(window)
            return true
        }
        return false
    }

    /// Content widths we once forced on every launch (`300+800`, then `300+720`).
    private static let supersededFactoryWidths: Set<Int> = [
        Int(Tokens.Sidebar.width + 800),
        Int(Tokens.Sidebar.width + 720),
    ]

    private static func isSupersededFactoryFrame(_ descriptor: String) -> Bool {
        // `NSWindow` frame strings are "x y w h …".
        let parts = descriptor.split(separator: " ")
        guard parts.count >= 4, let width = Double(parts[2]) else { return false }
        return supersededFactoryWidths.contains(Int(width.rounded()))
    }
}

/// Writes `PropellerMain` on every user resize/move. `setFrameAutosaveName`
/// alone was not enough: the window is often `orderOut`'d rather than closed,
/// and AppKit then never flushes the frame.
@MainActor
private final class MainWindowFramePersistence {
    static let shared = MainWindowFramePersistence()

    private var watched: ObjectIdentifier?
    private var observations: [NSObjectProtocol] = []

    func watch(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard watched != id else { return }
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations.removeAll()
        watched = id

        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observations.append(center.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self,
                          let noted = note.object as? NSWindow,
                          ObjectIdentifier(noted) == self.watched
                    else { return }
                    AppWindowRegistry.persistFrame(noted)
                }
            })
        }
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
        AppWindowRegistry.rememberFrame(on: window)
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
