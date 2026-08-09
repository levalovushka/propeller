import SwiftUI
import AppKit

/// # Меню строки меню — системное, а не нарисованное
///
/// Здесь пять команд и ни одной своей отрисовки. `MenuBarExtra` в стиле `.menu`
/// (он же стиль по умолчанию) собирает из этих кнопок настоящие пункты NSMenu —
/// с системной гарнитурой и кеглем, системным интервалом, системной подсветкой,
/// правильными эквивалентами клавиш, светлой и тёмной темой и доступностью,
/// которую нам иначе пришлось бы писать руками.
///
/// До этого меню было нарисованной стеклянной панелью (`.menuBarExtraStyle(.window)`
/// и свой `MenuBarPopover`), и первое, чем оно себя выдавало, — начертание:
/// строки шли medium, тогда как во всех остальных меню системы они regular. Это
/// ровно тот случай, когда «сделать похоже» дороже и хуже, чем взять настоящее:
/// панель нужна там, где внутри ползунки и переключатели, а у нас пять команд.
///
/// Разбирался, что именно даёт `.menu`, по документации `MenuBarExtra` и обзорам
/// стилей — see the commit message for the links.
struct MenuBarContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        // Один пункт на две команды, а не два, из которых один всегда мёртв.
        // Слот остаётся тем же — «запись», — и говорит, что с ней сейчас можно
        // сделать. Без него закрытое окно означало бы, что остановить запись
        // нечем: в чёлке стопа нет намеренно, а ⌘. требует фокуса на окне.
        Button(state.isRecording ? "Остановить запись" : "Начать запись") {
            if state.isRecording { state.stopRecording() } else { state.startRecording() }
        }
        Button("Открыть в окне") { AppWindowRegistry.showMain() }

        Divider()

        // Только «скрыть»: вернуть иконку можно из настроек, куда без неё ведёт
        // ⌘, и повторный запуск приложения.
        Button("Скрыть из меню-бара") { Preferences.shared.menuBarIconVisible = false }
        Button("Настройки…") { SettingsOpener.open() }
            .keyboardShortcut(",", modifiers: .command)
        Button("Выйти") { quit() }
            .keyboardShortcut("q", modifiers: .command)
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
