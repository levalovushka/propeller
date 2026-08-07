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
            // Только «скрыть»: вернуть иконку можно из настроек, куда без неё
            // ведёт ⌘, и повторный запуск приложения.
            onHideFromMenuBar: { Preferences.shared.menuBarIconVisible = false },
            onQuit: { quit() }
        )
    }

    private var status: MenuBarPopover.Status {
        if state.isRecording {
            // Именно записываемая встреча, а не выбранная: во время записи в
            // окне можно открыть любую другую, и меню-бар назвал бы её.
            let recorded = state.activeRecordingID
                .flatMap { state.recordingStore.recording(for: $0) }
            return .recording(title: recorded?.title ?? "Новая запись",
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
}
