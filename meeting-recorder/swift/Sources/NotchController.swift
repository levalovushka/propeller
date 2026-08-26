import AppKit
import SwiftUI
import PropellerUI
import PropellerPure

/// Панель у выреза: живёт ровно столько, сколько идёт запись.
///
/// Четыре кнопки: микрофон и вейвформа слева, пауза и стоп справа
/// (Figma 299:26711). Всё, что человек в звонке может захотеть за секунду, — и
/// ничего сверх того: заметки живут в окне встречи, а не здесь.
///
/// Плита ловит мышь только кнопками: всё остальное пропускает клик в меню-бар
/// под собой, потому что перекрывать меню чужого приложения на время встречи мы
/// права не имеем.
///
/// **Нет выреза — нет фичи, целиком.** Air M1, iMac, ноутбук с закрытой крышкой
/// на внешнем мониторе — панель там не поднимается. Пауза, стоп и микрофон
/// остаются доступными в окне и в меню-баре, то есть теряется удобство, а не
/// возможность.
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
    private var screenObserver: NSObjectProtocol?
    /// Плита уходит в вырез и только потом снимается — таск ждёт конца хода.
    private var dismissTask: Task<Void, Never>?

    private var stage: NotchGeometry.Stage = .open

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

    /// Пауза, мьют — состояние кнопок изменилось, плиту надо перерисовать.
    func refresh() {
        guard panel != nil else { return }
        render()
    }

    private func show() {
        guard panel == nil, let screen = Self.notchScreen() else { return }
        stage = .open

        // Окно сразу максимального габарита и больше не двигается: всё движение
        // плиты — внутри SwiftUI (`NotchFace`). Анимировать `setFrame` мы уже
        // пробовали, и на сворачивании плита отлипала от кромки экрана.
        let frame = Self.geometry(on: screen, stage: .open)
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
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        stage = .open
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
            // Крышку закрыли или встроенный экран ушёл: рисовать плиту не на
            // чем. Уходим молча, запись при этом идёт.
            hide()
            return
        }
        guard let panel else {
            // Крышку открыли посреди записи — вырез появился, плита вырастает
            // из него так же, как вырастала бы на старте.
            show()
            return
        }
        // Вырез на месте, но переехал или сменил размер: переключили
        // разрешение, переставили экраны в раскладке, сделали главным другой
        // монитор — тогда у экрана с вырезом меняется его левый край, а с ним и
        // рамка. Окно переезжает без анимации: это движение железа, а не
        // интерфейса.
        panel.setFrame(Self.geometry(on: screen, stage: .open), display: true)
        render()
    }

    // MARK: - Действия

    private func toggleMute() {
        state?.toggleMicMuted()
    }

    private func togglePause() {
        guard let state, state.isRecording else { return }
        if state.isRecordingPaused { state.resumeRecording() } else { state.pauseRecording() }
    }

    private func stop() {
        state?.stopRecording()
    }

    // MARK: - Геометрия и отрисовка

    /// Единственный экран, на котором эта фича может существовать: тот, у
    /// которого физически есть вырез. Подставлять `NSScreen.main` нельзя —
    /// именно так плита однажды и оказывалась плашкой на внешнем мониторе.
    ///
    /// Края отдаются целиком (`minX` и `maxY`, а не одна ширина): рамка панели
    /// живёт в общих координатах рабочего стола, и экран, у которого не забрали
    /// левый край, неотличим от главного. Ровно из-за этого чёлка вырастала на
    /// внешнем мониторе у тех, кто сделал главным его, а не ноутбук.
    private static func notchScreen() -> NotchGeometry.Screen? {
        for screen in NSScreen.screens {
            if let model = NotchGeometry.screen(
                left: screen.frame.minX,
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
        NotchFace(
            screen: screen,
            stage: stage,
            paused: state?.isRecordingPaused == true,
            muted: state?.isMicMuted == true,
            canMute: state?.canMuteMic == true,
            onMute: { [weak self] in self?.toggleMute() },
            onPause: { [weak self] in self?.togglePause() },
            onStop: { [weak self] in self?.stop() }
        )
    }
}

/// Панель, которая принимает клики, не активируя приложение: нажать паузу
/// посреди звонка нельзя ценой выдёргивания человека из Zoom.
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
