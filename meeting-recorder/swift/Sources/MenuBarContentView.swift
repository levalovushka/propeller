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

    /// Единственный способ **создать** окно заново.
    ///
    /// `AppWindowRegistry.showMain()` умеет показать окно, которое есть, — но
    /// закрытое окно `WindowGroup` SwiftUI уничтожает, и `mainWindow()` тогда
    /// возвращает nil. В этом случае `showMain` активировал приложение и
    /// возвращался, то есть «Открыть в окне» не делало ничего — ровно то, что
    /// человек и видел. Открыть сцену из AppKit нечем: окном владеет SwiftUI, и
    /// просить его надо через это действие.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Один пункт на две команды, а не два, из которых один всегда мёртв.
        // Слот остаётся тем же — «запись», — и говорит, что с ней сейчас можно
        // сделать. Без него закрытое окно означало бы, что остановить запись
        // нечем: в чёлке стопа нет намеренно, а ⌘. требует фокуса на окне.
        Button(state.isRecording ? "Остановить запись" : "Начать запись") {
            if state.isRecording { state.stopRecording() } else { state.startRecording() }
        }
        Button("Открыть в окне") { openMainWindow() }

        Divider()

        // Только «скрыть»: вернуть иконку можно из настроек, куда без неё ведёт
        // ⌘, и повторный запуск приложения.
        Button("Скрыть из меню-бара") { Preferences.shared.menuBarIconVisible = false }
        Button("Настройки…") { SettingsOpener.open() }
            .keyboardShortcut(",", modifiers: .command)
        Button("Выйти") { quit() }
            .keyboardShortcut("q", modifiers: .command)
    }

    /// Оба шага, и в этом порядке.
    ///
    /// `openWindow` создаёт сцену, если её нет, и поднимает существующую, но не
    /// знает про две вещи, которые делает `showMain`: альфу (закрытое на время
    /// онбординга окно спрятано через `alphaValue = 0` + `orderOut`, и само по
    /// себе оно вернулось бы невидимым) и сохранённый кадр. Второй шаг — через
    /// `async`, потому что окно, которое SwiftUI только что попросили создать,
    /// в этом такте в `NSApp.windows` ещё не появилось.
    private func openMainWindow() {
        openWindow(id: AppWindowRole.main.rawValue)
        // `centered:` по умолчанию, как у возврата через Dock
        // (`applicationShouldHandleReopen`): один способ вернуть окно — одно
        // поведение. Сохранённый кадр всё равно старше центрирования
        // (`applySavedFrame`), так что центр достаётся только окну, которого
        // до этого не было ни разу.
        DispatchQueue.main.async { AppWindowRegistry.showMain() }
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
