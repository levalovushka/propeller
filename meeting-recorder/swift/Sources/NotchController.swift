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
@MainActor
final class NotchController {
    static let shared = NotchController()

    private weak var state: AppState?
    private var panel: NotchPanel?
    private var hosting: NSHostingView<NotchFace>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    private var stage: NotchGeometry.Stage = .resting

    /// ⌃⌥N — keyCode 45 это «n».
    private let noteKeyCode: UInt16 = 45

    func install(state: AppState) {
        self.state = state
    }

    // MARK: - Жизнь панели

    /// Запись пошла: плита вырастает, монитор клавиши встаёт.
    func startRecording() {
        stage = .resting
        show()
        startMonitoring()
    }

    /// Запись кончилась любым способом — плита уходит целиком.
    func stopRecording() {
        stopMonitoring()
        hide()
    }

    /// Пауза меняет только лопасть, но перерисовать плиту всё равно надо.
    func refresh() {
        guard panel != nil else { return }
        render()
    }

    private func show() {
        guard panel == nil, let screen = Self.notchScreen() else { return }

        // Окно сразу максимального габарита и больше не двигается: всё движение
        // плиты — внутри SwiftUI (`NotchFace`). Анимировать `setFrame` мы уже
        // пробовали, и на сворачивании плита отлипала от кромки экрана.
        let frame = Self.geometry(for: screen, stage: .composing)
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

        let hosting = NSHostingView(rootView: face())
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel

        panel.orderFrontRegardless()

        // Экраны переставили, крышку закрыли, монитор отключили — геометрия
        // выреза меняется под нами, и плита обязана переехать вместе с ней.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
    }

    private func hide() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        stage = .resting
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

    /// Экран с вырезом; без него — главный, там плита живёт пилюлей.
    private static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private static func geometry(for screen: NSScreen, stage: NotchGeometry.Stage) -> NSRect {
        let frame = NotchGeometry.frame(on: model(of: screen), stage: stage)
        return NSRect(x: frame.originX, y: frame.originY,
                      width: frame.width, height: frame.height)
    }

    private static func model(of screen: NSScreen) -> NotchGeometry.Screen {
        let f = screen.frame
        let notchWidth = NotchGeometry.notchWidth(
            screenWidth: f.width,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width ?? f.width / 2,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width ?? f.width / 2
        )
        return NotchGeometry.Screen(
            width: f.width,
            top: f.maxY,
            notchWidth: notchWidth,
            notchHeight: screen.safeAreaInsets.top
        )
    }

    /// Экраны переставили — окно переезжает целиком, без анимации: это не
    /// движение интерфейса, а смена железа под ним.
    private func relayout() {
        guard let panel, let screen = Self.notchScreen() else { return }
        panel.setFrame(Self.geometry(for: screen, stage: .composing), display: true)
        render()
    }

    private func render() {
        hosting?.rootView = face()
    }

    private func face() -> NotchFace {
        let screen = Self.notchScreen()
        let recorder = state?.recorder
        return NotchFace(
            screen: screen.map { Self.model(of: $0) }
                ?? NotchGeometry.Screen(width: 0, top: 0, notchWidth: 0, notchHeight: 0),
            stage: stage,
            paused: state?.isRecordingPaused == true,
            level: { [weak recorder] in
                guard let recorder else { return 0 }
                return max(recorder.micLevelHistory.last ?? 0,
                           recorder.systemLevelHistory.last ?? 0)
            },
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
