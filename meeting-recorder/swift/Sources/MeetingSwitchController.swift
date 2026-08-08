import AppKit
import Combine
import PropellerPure
import PropellerUI

/// # ⌥Tab между встречами
///
/// Держат ⌥, стучат Tab, отпускают — открывается та, на которой отпустили. Пока
/// клавишу держат, не открывается ничего: `AppState.selectRecording` останавливает
/// плеер, проверяет диск и кладёт запись в историю навигации, и делать это двадцать
/// раз по дороге к двадцать первой встрече — значит превратить прогулку по списку в
/// двадцать открытий. Куда прогулка дошла, знает `MeetingSwitch`; здесь только
/// клавиши и одно приземление.
///
/// Первый Tab сразу делает шаг, как ⌘Tab делает шаг на предыдущее приложение:
/// панель появляется, когда выделение уже на следующей встрече, а та, с которой
/// ушли, стоит строкой выше. Иначе первое нажатие ничего не переключало бы, и
/// стучать пришлось бы на один раз больше, чем кажется.
///
/// Почему AppKit, а не `keyboardShortcut`: Tab перехватывает система фокуса ещё до
/// SwiftUI, а «пока клавиша нажата» в SwiftUI не выражается вовсе — нужен
/// `flagsChanged`, чтобы узнать про отпускание ⌥. Монитор локальный: это жест
/// внутри окна, а не горячая клавиша системы.
@MainActor
final class MeetingSwitchController: ObservableObject {

    /// Прогулка, если она идёт.
    @Published private(set) var walk: MeetingSwitch?

    /// Стоит ли уже показывать панель. Не то же самое, что «идёт прогулка»:
    /// стукнуть ⌥Tab и отпустить — это переключиться, а не листать, и плита,
    /// мигнувшая над окном по дороге, там только мешает. Поэтому панель ждёт
    /// `appearDelay` и не появляется вовсе, если ⌥ отпустили раньше.
    @Published private(set) var showsPanel = false

    private var panelTimer: Task<Void, Never>?

    private var order: () -> [String] = { [] }
    private var selectedID: () -> String? = { nil }
    private var openMeeting: (String) -> Void = { _ in }

    private var keyMonitor: Any?
    private var flagsMonitor: Any?

    /// Tab — 48, Escape — 53. Числа Carbon'а, других имён у них нет.
    private static let tabKeyCode: UInt16 = 48
    private static let escapeKeyCode: UInt16 = 53

    /// Окно отдаёт свои три ответа здесь, а не в `init`: `@StateObject` строится
    /// раньше, чем у вида есть `AppState`.
    func start(
        order: @escaping () -> [String],
        selectedID: @escaping () -> String?,
        openMeeting: @escaping (String) -> Void
    ) {
        self.order = order
        self.selectedID = selectedID
        self.openMeeting = openMeeting
        guard keyMonitor == nil, flagsMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Уйти из прогулки, ничего не открыв — как в любом переключателе.
            if event.keyCode == Self.escapeKeyCode, self.walk != nil {
                self.end()
                return nil
            }
            guard event.keyCode == Self.tabKeyCode, flags.contains(.option) else { return event }

            let step = flags.contains(.shift) ? -1 : 1
            // Порядок берётся один раз, на первом нажатии: если конвейер допишет
            // встречу посреди прогулки, список под рукой не должен поехать.
            let started = self.walk ?? MeetingSwitch(order: self.order(), startingAt: self.selectedID())
            // Нечего листать — пусть Tab останется Tab'ом: съеденная клавиша,
            // которая ничего не сделала, это сломанная клавиша.
            guard let started else { return event }
            let isFirstStep = self.walk == nil
            self.walk = started.stepped(by: step)
            if isFirstStep { self.armPanel() }
            // Съедаем Tab целиком: иначе он же уедет в поле саммари и вставит
            // там табуляцию.
            return nil
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, let walk = self.walk else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.contains(.option) else { return event }
            self.end()
            // Вернуться туда, откуда ушёл, — это не переход: открывать заново уже
            // открытое значит остановить плеер и положить в историю пустой шаг.
            guard walk.currentID != self.selectedID() else { return event }
            self.openMeeting(walk.currentID)
            return event
        }
    }

    /// Панель ждёт своей задержки. Отсчёт один на прогулку, от первого шага: если
    /// перезапускать его на каждом Tab, панель не появится, пока по списку идут, —
    /// то есть ровно тогда, когда она и нужна.
    private func armPanel() {
        panelTimer?.cancel()
        panelTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Tokens.Pane.Switcher.appearDelay))
            guard !Task.isCancelled, let self, self.walk != nil else { return }
            self.showsPanel = true
        }
    }

    private func end() {
        panelTimer?.cancel()
        panelTimer = nil
        walk = nil
        showsPanel = false
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
        end()
    }
}
