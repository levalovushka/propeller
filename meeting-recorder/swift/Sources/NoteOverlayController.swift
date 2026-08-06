import AppKit
import SwiftUI
import PropellerUI

/// A borderless panel that can still take keyboard focus (needed to type into
/// the quick-note field without fully activating the app).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Global-shortcut quick-note overlay (plan-v2 4.8). While a recording is in
/// progress, ⌃⌥N drops a translucent input at the bottom of the screen; Enter
/// saves the note with the current recording timecode and dismisses it, Esc
/// cancels. Active only during recording; no settings.
///
/// The global key monitor needs Accessibility/Input Monitoring permission to
/// fire when another app (e.g. Zoom) is focused. Without it, the shortcut still
/// works while Propeller itself is frontmost (local monitor).
@MainActor
final class NoteOverlayController {
    static let shared = NoteOverlayController()

    private weak var state: AppState?
    private var panel: KeyablePanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var confirmTask: Task<Void, Never>?

    /// Ctrl+Opt+N — keyCode 45 is "n".
    private let noteKeyCode: UInt16 = 45

    /// Keep a reference to AppState; key monitors are installed only while
    /// recording (plan-optimization E7) so idle keystrokes aren't taxed.
    func install(state: AppState) {
        self.state = state
    }

    func startMonitoring() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == self.noteKeyCode, flags.contains(.control), flags.contains(.option) {
                self.toggle()
            }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { handler($0) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }
    }

    func stopMonitoring() {
        if let g = globalMonitor {
            NSEvent.removeMonitor(g)
            globalMonitor = nil
        }
        if let l = localMonitor {
            NSEvent.removeMonitor(l)
            localMonitor = nil
        }
        hide()
    }

    private func toggle() {
        guard let state, state.isRecording else { return }   // only while recording
        if panel?.isVisible == true { hide() } else { show() }
    }

    private func show() {
        let hosting = NSHostingView(rootView: NoteInputView(
            onSubmit: { [weak self] text in self?.commit(text) },
            onCancel: { [weak self] in self?.hide() }
        ))

        let width: CGFloat = 440, height: CGFloat = 58
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let sf = screen.frame
            panel.setFrameOrigin(NSPoint(x: sf.midX - width / 2, y: sf.minY + 140))
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    private func hide() {
        confirmTask?.cancel()
        confirmTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func commit(_ text: String) {
        if state?.appendTimestampedNote(text) == true { confirmSaved() } else { hide() }
    }

    /// Confirm the save where the typing happened: the field becomes a tick for a
    /// beat, then the panel goes by itself.
    ///
    /// This replaced a system notification — one that arrived with a sound, in
    /// the middle of a recording, about something the user had just done. A
    /// recorder that beeps into its own microphone is the one notification that
    /// damages the thing it is reporting on.
    private func confirmSaved() {
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: NoteSavedView())
        confirmTask?.cancel()
        confirmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }
}

/// The same 440×58 plate as the input, so nothing jumps when it swaps.
private struct NoteSavedView: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Заметка сохранена")
                .typo(Tokens.Typography.Label.mdRegular)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 440, height: 58)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                .strokeBorder(Tokens.Neutral.aw7, lineWidth: 1)
        )
    }
}

private struct NoteInputView: View {
    var onSubmit: (String) -> Void
    var onCancel: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
            TextField("Быстрая заметка…", text: $text)
                .textFieldStyle(.plain)
                .typo(Tokens.Typography.Label.mdRegular)
                .focused($focused)
                .onSubmit {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { onSubmit(t) }
                    onCancel()
                }
                .onExitCommand { onCancel() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 440, height: 58)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                .strokeBorder(Tokens.Neutral.aw7, lineWidth: 1)
        )
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }
}
