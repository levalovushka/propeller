import AppKit
import SwiftUI
import PropellerUI
import PropellerPure

/// Панель у выреза: живёт ровно столько, сколько идёт запись.
///
/// Заменила нижний оверлей заметки (⌃⌥N). Причина не в том, что так красивее:
/// камера — в чёлке, и человек, печатающий в поле, которое выросло из выреза,
/// на встрече продолжает выглядеть смотрящим в глаза. Нижняя плашка уводила
/// взгляд вниз, и это видели все участники.
///
/// Два элемента и одно действие: слева лопасть, которую крутит записываемый
/// звук, справа заметка. Паузы и стопа тут нет — см. `NotchSurface`.
///
/// Плита ловит мышь только своим правым ухом: всё остальное пропускает клик в
/// меню-бар под собой, потому что перекрывать меню чужого приложения на время
/// встречи мы права не имеем.
///
/// **Нет выреза — нет фичи, целиком.** Air M1, iMac, ноутбук с закрытой крышкой
/// на внешнем мониторе — там не поднимается ни панель, ни монитор ⌃⌥N. Второе
/// важнее первого: горячая клавиша, открывающая поле, которого не видно, — это
/// клавиатура, проваливающаяся в никуда посреди встречи. Заметки в таком случае
/// живут в колонке окна, где они есть всегда.
///
/// Вырез может появиться и исчезнуть посреди записи (крышку открыли, монитор
/// отключили, разрешение переключили) — поэтому наблюдатель за экранами живёт
/// всю запись, а не пока стоит панель.
@MainActor
final class NotchController {
    static let shared = NotchController()

    private weak var state: AppState?
    private var panel: NotchPanel?
    private var hosting: NSHostingView<NotchFace>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    /// Плита уходит в вырез и только потом снимается — таск ждёт конца хода.
    private var dismissTask: Task<Void, Never>?

    private var stage: NotchGeometry.Stage = .resting

    /// ⌃⌥N — keyCode 45 это «n».
    private let noteKeyCode: UInt16 = 45

    func install(state: AppState) {
        self.state = state
    }

    // MARK: - Жизнь панели

    /// Есть ли на этой машине вырез, с которым можно работать. Настройкам
    /// нужно знать это, чтобы не предлагать выключить то, чего нет.
    static var hardwareHasNotch: Bool { notchScreen() != nil }

    /// Человек выключил или включил чёлку в настройках посреди записи.
    func preferenceChanged() {
        guard state?.isRecording == true else { return }
        if Preferences.shared.notchIndicator {
            observeScreens()
            show()
        } else {
            stopObservingScreens()
            hide()
        }
    }

    /// Запись пошла: если на этой машине есть вырез — плита вырастает из него.
    func startRecording() {
        dismissTask?.cancel()
        dismissTask = nil
        guard Preferences.shared.notchIndicator else { return }
        observeScreens()
        show()
    }

    /// Запись кончилась любым способом. Плита не исчезает, а уходит обратно в
    /// вырез: появилась она оттуда же.
    func stopRecording() {
        stopObservingScreens()
        stopMonitoring()
        guard panel != nil else { return }
        stage = .sealed
        render()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.dismissDelayMs))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Ход `NotchFace.leave` плюс запас: снять окно раньше — значит оборвать
    /// уход на середине, позже — оставить на экране чёрный прямоугольник,
    /// который уже ничего не показывает.
    private static let dismissDelayMs = 620

    /// Пауза меняет только лопасть, но перерисовать плиту всё равно надо.
    func refresh() {
        guard panel != nil else { return }
        render()
    }

    private func show() {
        guard panel == nil, let screen = Self.notchScreen() else { return }
        stage = .resting

        // Окно сразу максимального габарита и больше не двигается: всё движение
        // плиты — внутри SwiftUI (`NotchFace`). Анимировать `setFrame` мы уже
        // пробовали, и на сворачивании плита отлипала от кромки экрана.
        let frame = Self.geometry(on: screen, stage: .composing)
        let panel = NotchPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        // Выше меню-бара и Дока — иначе плита не смыкается с вырезом, а
        // прячется под строкой меню и перестаёт быть чёлкой.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        // Встреча идёт в чужом полноэкранном окне и в чужом Space: плита должна
        // быть везде, где может оказаться человек, и никуда не уезжать.
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]

        let hosting = NSHostingView(rootView: face(on: screen))
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel

        panel.orderFrontRegardless()
        startMonitoring()
    }

    private func hide() {
        stopMonitoring()
        panel?.resignKey()
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        stage = .resting
    }

    /// Экраны переставили, крышку открыли или закрыли, разрешение переключили —
    /// вырез появляется, исчезает и меняет размер под нами, всё это посреди
    /// записи. Одна точка, которая на это отвечает.
    private func observeScreens() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    private func stopObservingScreens() {
        guard let screenObserver else { return }
        NotificationCenter.default.removeObserver(screenObserver)
        self.screenObserver = nil
    }

    private func screensChanged() {
        guard state?.isRecording == true, Preferences.shared.notchIndicator else { return }
        guard let screen = Self.notchScreen() else {
            // Крышку закрыли или встроенный экран ушёл: чёлки нет, а значит нет
            // и фичи — вместе с горячей клавишей, которой больше некуда открыть
            // поле. Уходим молча, запись при этом идёт.
            hide()
            return
        }
        guard let panel else {
            // Крышку открыли посреди записи — вырез появился, плита вырастает
            // из него так же, как вырастала бы на старте.
            show()
            return
        }
        // Тот же вырез другого размера (переключили разрешение) — окно
        // переезжает без анимации: это движение железа, а не интерфейса.
        panel.setFrame(Self.geometry(on: screen, stage: .composing), display: true)
        render()
    }

    // MARK: - Заметка

    private func startMonitoring() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == self.noteKeyCode, flags.contains(.control), flags.contains(.option) {
                self.toggleNote()
            }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { handler($0) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }
    }

    private func stopMonitoring() {
        if let g = globalMonitor {
            NSEvent.removeMonitor(g)
            globalMonitor = nil
        }
        if let l = localMonitor {
            NSEvent.removeMonitor(l)
            localMonitor = nil
        }
    }

    private func toggleNote() {
        guard state?.isRecording == true else { return }
        if stage == .composing { cancelNote() } else { openNote() }
    }

    private func openNote() {
        guard panel != nil else { return }
        stage = .composing
        render()
        // Фокус клавиатуры без активации приложения: человек в звонке, и
        // выдёргивать Zoom из-под него ради одной строки нельзя.
        panel?.makeKeyAndOrderFront(nil)
    }

    private func cancelNote() {
        stage = .resting
        render()
        panel?.resignKey()
    }

    /// Заметка записана — и это всё, что об этом сообщается: поле закрылось.
    private func commitNote(_ text: String) {
        _ = state?.appendTimestampedNote(text)
        stage = .resting
        render()
        panel?.resignKey()
    }

    // MARK: - Геометрия и отрисовка

    /// Единственный экран, на котором эта фича может существовать: тот, у
    /// которого физически есть вырез. Подставлять `NSScreen.main` нельзя —
    /// именно так плита однажды и оказывалась плашкой на внешнем мониторе.
    private static func notchScreen() -> NotchGeometry.Screen? {
        for screen in NSScreen.screens {
            if let model = NotchGeometry.screen(
                width: screen.frame.width,
                top: screen.frame.maxY,
                safeAreaTop: screen.safeAreaInsets.top,
                auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
                auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width
            ) {
                return model
            }
        }
        return nil
    }

    /// Сколько раз привод лопасти опоздал и насколько. Пишется раз в десять
    /// секунд: цифра нужна, чтобы знать, стоял ли главный поток, — сам поворот
    /// от этого уже не зависит, он живёт в слое.
    private static var stalls = 0
    private static var worstStall: Double = 0
    private static var stallWindow: Date?

    private static func noteStall(_ seconds: Double) {
        let now = Date()
        stalls += 1
        worstStall = max(worstStall, seconds)
        guard let started = stallWindow else {
            stallWindow = now
            return
        }
        let elapsed = now.timeIntervalSince(started)
        guard elapsed >= 10 else { return }
        debugLog(String(
            format: "[Notch] привод опоздал %d раз за %.0f с, худший — %.0f мс",
            stalls, elapsed, worstStall * 1000
        ))
        Analytics.signal("Notch.bladeStall", value: worstStall * 1000)
        stalls = 0
        worstStall = 0
        stallWindow = now
    }

    private static func geometry(on screen: NotchGeometry.Screen, stage: NotchGeometry.Stage) -> NSRect {
        let frame = NotchGeometry.frame(on: screen, stage: stage)
        return NSRect(x: frame.originX, y: frame.originY,
                      width: frame.width, height: frame.height)
    }

    private func render() {
        guard let hosting else { return }
        // Вырез мог исчезнуть между кадром и кадром — рисовать плиту не на чем.
        guard let screen = Self.notchScreen() else {
            hide()
            return
        }
        hosting.rootView = face(on: screen)
    }

    private func face(on screen: NotchGeometry.Screen) -> NotchFace {
        let recorder = state?.recorder
        return NotchFace(
            screen: screen,
            stage: stage,
            paused: state?.isRecordingPaused == true,
            level: { [weak recorder] in
                guard let recorder else { return 0 }
                return max(recorder.micLevelHistory.last ?? 0,
                           recorder.systemLevelHistory.last ?? 0)
            },
            onStall: { seconds in Self.noteStall(seconds) },
            onNote: { [weak self] in self?.toggleNote() },
            onCommit: { [weak self] text in self?.commitNote(text) },
            onCancel: { [weak self] in self?.cancelNote() }
        )
    }
}

/// Панель, которая умеет взять клавиатуру, не активируя приложение, — иначе
/// первая же заметка выдернула бы человека из звонка.
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
