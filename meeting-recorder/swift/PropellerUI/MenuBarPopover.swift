import SwiftUI
import AppKit

/// # Меню-бар — пять команд и ничего больше
///
/// Он был маленьким приложением: шапка с именем и версией, стрелка в угол,
/// живой заголовок записываемой встречи с таймером, красная кнопка стопа,
/// «Стоп и сбросить», строка фазы обработки. Всё это уже есть в окне, и лучше:
/// таймер идёт в чёлке и на строке рельса, фазу говорит рельс, сброс записи
/// спрашивает подтверждение, которому в поповере негде появиться.
///
/// Значок в строке меню — не место для интерфейса. Это системное меню приложения,
/// и в нём ровно то, чего нельзя сделать больше нигде, когда окна перед глазами
/// нет: начать (или остановить) запись, открыть окно, убрать значок, настройки,
/// выйти. Без иконок: пять строк подряд не нуждаются в опознавательных знаках,
/// а системные меню macOS их и не носят.
public struct MenuBarPopover: View {
    var isRecording: Bool
    var onOpenWindow: () -> Void
    var onStartRecording: () -> Void
    var onStop: () -> Void
    var onSettings: () -> Void
    /// Убрать иконку из строки меню. Отсюда её можно только убрать: вернуть
    /// нечем — поповера без иконки не существует, — и возврат живёт в настройках
    /// («Основное»), а не здесь. Absent — строки нет.
    var onHideFromMenuBar: (() -> Void)?
    var onQuit: () -> Void

    public init(
        isRecording: Bool,
        onOpenWindow: @escaping () -> Void,
        onStartRecording: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onHideFromMenuBar: (() -> Void)? = nil,
        onQuit: @escaping () -> Void
    ) {
        self.isRecording = isRecording
        self.onOpenWindow = onOpenWindow
        self.onStartRecording = onStartRecording
        self.onStop = onStop
        self.onSettings = onSettings
        self.onHideFromMenuBar = onHideFromMenuBar
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Одна строка на две команды, а не две строки, одна из которых
            // всегда мертва. Пункт остаётся тем же — «запись», — и говорит, что
            // с ней сейчас можно сделать. Без него закрытое окно означало бы,
            // что остановить запись нечем: в чёлке стопа нет намеренно, а ⌘.
            // требует фокуса на окне.
            MenuRow(
                title: isRecording ? "Остановить запись" : "Начать запись",
                action: isRecording ? onStop : onStartRecording
            )
            MenuRow(title: "Открыть в окне", action: onOpenWindow)
            if let onHideFromMenuBar {
                MenuRow(title: "Скрыть из меню-бара", action: onHideFromMenuBar)
            }
            MenuRow(title: "Настройки…", shortcut: "⌘,", action: onSettings)
                .keyboardShortcut(",", modifiers: .command)
            MenuRow(title: "Выйти", shortcut: "⌘Q", action: onQuit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(6)
        .frame(width: 220)
        .background(GlassBackground(material: .regularMaterial, tinted: false))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
    }
}

/// A popover menu row: SF Pro Medium 12, hover fills a 6pt rounded highlight.
///
/// Title, then the key equivalent on the trailing edge — the system menu layout
/// minus the icon column. Значков нет: они стояли у трёх строк из пяти, то есть
/// не различали, а украшали, — а по системным меню macOS их и не носят.
private struct MenuRow: View {
    let title: String
    var shortcut: String? = nil
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .typo(Tokens.Typography.Label.smMedium)
                    .foregroundStyle(Tokens.Ink.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let shortcut {
                    Text(shortcut)
                        .typo(Tokens.Typography.Label.smRegular)
                        .foregroundStyle(Tokens.Ink.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(hovering ? Tokens.Paint.Interactive.Ghost.hover : Color.clear,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.xxs, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.xxs, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

#Preview("Popover states") {
    HStack(alignment: .top, spacing: 24) {
        MenuBarPopover(isRecording: false, onOpenWindow: {}, onStartRecording: {},
                       onStop: {}, onSettings: {}, onHideFromMenuBar: {}, onQuit: {})
        MenuBarPopover(isRecording: true, onOpenWindow: {}, onStartRecording: {},
                       onStop: {}, onSettings: {}, onHideFromMenuBar: {}, onQuit: {})
    }
    .padding(40)
    .background(Color(white: 0.12))
}
