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
    private var confirmTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    private var stage: NotchGeometry.Stage = .resting
    /// Сколько заметок вписано в эту встречу. Счётчик сессии, а не файла: он
    /// нужен как подтверждение («их теперь три»), а не как учёт.
    private var noteCount = 0
    /// Число, которое ухо показывает вместо значка сразу после сохранения.
    private var confirming: Int?

    /// ⌃⌥N — keyCode 45 это «n».
    private let noteKeyCode: UInt16 = 45

    func install(state: AppState) {
        self.state = state
    }

    // MARK: - Жизнь панели

    /// Запись пошла: плита вырастает, монитор клавиши встаёт.
    func startRecording() {
        noteCount = 0
        confirming = nil
        stage = .resting
        show()
        startMonitoring()
    }

    /// Запись кончилась любым способом — плита уходит целиком.
    func stopRecording() {
        stopMonitoring()
        confirmTask?.cancel()
        confirmTask = nil
        hide()
    }

    /// Пауза меняет только лопасть, но перерисовать плиту всё равно надо.
    func refresh() {
        guard panel != nil else { return }
        render()
    }

    private func show() {
        guard panel == nil, let screen = Self.notchScreen() else { return }

        let frame = Self.geometry(for: screen, stage: stage)
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

        let hosting = NSHostingView(rootView: face(frame: frame))
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
            MainActor.assumeIsolated { self?.relayout(animated: false) }
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
        confirming = nil
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
        confirmTask?.cancel()
        confirming = nil
        stage = .composing
        relayout(animated: true)
        // Фокус клавиатуры без активации приложения: человек в звонке, и
        // выдёргивать Zoom из-под него ради одной строки нельзя.
        panel?.makeKeyAndOrderFront(nil)
    }

    private func cancelNote() {
        stage = .resting
        relayout(animated: true)
        panel?.resignKey()
    }

    private func commitNote(_ text: String) {
        let saved = state?.appendTimestampedNote(text) == true
        stage = .resting
        if saved {
            noteCount += 1
            confirming = noteCount
        }
        relayout(animated: true)
        panel?.resignKey()

        guard saved else { return }
        confirmTask?.cancel()
        confirmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.confirming = nil
            self?.render()
        }
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

    private func relayout(animated: Bool) {
        guard let panel, let screen = Self.notchScreen() else { return }
        let rect = Self.geometry(for: screen, stage: stage)
        render(frame: rect)
        guard animated else {
            panel.setFrame(rect, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(rect, display: true)
        }
    }

    private func render(frame: NSRect? = nil) {
        guard let hosting, let screen = Self.notchScreen() else { return }
        let rect = frame ?? Self.geometry(for: screen, stage: stage)
        hosting.rootView = face(frame: rect)
    }

    private func face(frame rect: NSRect) -> NotchFace {
        let screen = Self.notchScreen()
        let layout = screen.map { NotchGeometry.frame(on: Self.model(of: $0), stage: stage) }
        let recorder = state?.recorder
        return NotchFace(
            frame: layout ?? NotchGeometry.frame(
                on: NotchGeometry.Screen(width: rect.width, top: rect.maxY,
                                         notchWidth: 0, notchHeight: rect.height),
                stage: stage
            ),
            composing: stage == .composing,
            paused: state?.isRecordingPaused == true,
            savedCount: confirming,
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
