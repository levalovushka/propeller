import SwiftUI
import AppKit
import PropellerUI

/// Bridges `AppState` to the reusable `MenuBarPopover`.
///
/// Осталось одно наблюдаемое поле — идёт ли запись. Фазу обработки поповер
/// больше не показывает: она и так стоит на строке встречи в рельсе, а здесь
/// была третьим местом, где та же мысль пишется своими словами.
struct MenuBarContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        MenuBarPopover(
            isRecording: state.isRecording,
            onOpenWindow: { AppWindowRegistry.showMain() },
            onStartRecording: { state.startRecording() },
            onStop: { state.stopRecording() },
            onSettings: { SettingsOpener.open() },
            // Только «скрыть»: вернуть иконку можно из настроек, куда без неё
            // ведёт ⌘, и повторный запуск приложения.
            onHideFromMenuBar: { Preferences.shared.menuBarIconVisible = false },
            onQuit: { quit() }
        )
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
