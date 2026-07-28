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
        // One question instead of three step flags — and the summary phase is
        // included by construction, not by remembering to list it
        // (release-review rev-17).
        if let message = state.activity.message {
            return .processing(message)
        }
        return .idle
    }

    private func quit() {
        if state.isRecording {
            Task {
                await state.stopRecordingAndWait(runPipeline: false)
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
