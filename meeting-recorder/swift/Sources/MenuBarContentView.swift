import SwiftUI
import AppKit
import PropellerUI

/// Bridges `AppState` to the reusable `MenuBarPopover`: maps the app's status to
/// the popover's three states and wires the row actions to existing app methods.
struct MenuBarContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        MenuBarPopover(
            status: status,
            onOpenWindow: { MenuBarPanelView.showMainWindow() },
            onStartRecording: { state.startRecording() },
            onStop: { state.stopRecording() },
            onDiscard: { state.cancelRecording() },
            onSettings: { SettingsOpener.open() },
            onRestart: { Self.relaunch() },
            onQuit: { quit() }
        )
    }

    private var status: MenuBarPopover.Status {
        if state.isRecording {
            return .recording(title: state.selectedRecording?.title ?? "Новая запись",
                              elapsed: state.elapsedString)
        }
        // Recap counts as work — without it the menu bar read "idle" for the
        // whole summary step (release-review rev-17).
        if state.transcribeStep == .running || state.saveStep == .running
            || state.recapStep == .running {
            return .processing(state.statusMessage.isEmpty ? "Обработка…" : state.statusMessage)
        }
        return .idle
    }

    private func quit() {
        if state.isRecording {
            Task {
                await state.stopRecordingAndWait()
                state.recordingStore.flush()
                await MainActor.run { NSApplication.shared.terminate(nil) }
            }
        } else {
            state.recordingStore.flush()
            NSApplication.shared.terminate(nil)
        }
    }

    /// Relaunch the app (a fresh instance replaces this one).
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }
}
