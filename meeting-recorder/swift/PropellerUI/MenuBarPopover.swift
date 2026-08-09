import SwiftUI
import AppKit

/// The menu-bar popover: a small glass panel with a header (name + version +
/// open-window), a state-dependent primary row, and Settings / Quit.
/// Data-driven — the app passes `status` and the callbacks. Verified against
/// Figma 632:754 (idle / started / stopped).
public struct MenuBarPopover: View {
    public enum Status: Equatable {
        case idle
        case recording(title: String, elapsed: String)
        case processing(String)   // e.g. "Saving…"
    }

    var version: String
    var status: Status
    var onOpenWindow: () -> Void
    var onStartRecording: () -> Void
    var onStop: () -> Void
    var onDiscard: (() -> Void)?
    var onSettings: () -> Void
    /// Убрать иконку из строки меню. Отсюда её можно только убрать: вернуть
    /// нечем — поповера без иконки не существует, — и возврат живёт в настройках
    /// («Основное»), а не здесь. Absent — строки нет.
    var onHideFromMenuBar: (() -> Void)?
    var onQuit: () -> Void

    public init(
        version: String = "v0.1 Beta",
        status: Status,
        onOpenWindow: @escaping () -> Void,
        onStartRecording: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onDiscard: (() -> Void)? = nil,
        onSettings: @escaping () -> Void,
        onHideFromMenuBar: (() -> Void)? = nil,
        onQuit: @escaping () -> Void
    ) {
        self.version = version
        self.status = status
        self.onOpenWindow = onOpenWindow
        self.onStartRecording = onStartRecording
        self.onStop = onStop
        self.onDiscard = onDiscard
        self.onSettings = onSettings
        self.onHideFromMenuBar = onHideFromMenuBar
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            divider
            primary
            divider
            MenuRow(
                title: "Настройки…",
                symbol: "gearshape",
                shortcut: "⌘,",
                action: onSettings
            )
            .keyboardShortcut(",", modifiers: .command)
            if let onHideFromMenuBar {
                MenuRow(
                    title: "Скрыть из меню-бара",
                    symbol: "eye.slash",
                    action: onHideFromMenuBar
                )
            }
            MenuRow(
                title: "Выйти",
                symbol: "xmark.circle",
                shortcut: "⌘Q",
                action: onQuit
            )
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(6)
        .frame(width: 260)
        .background(GlassBackground(material: .regularMaterial, tinted: false))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Propeller").foregroundStyle(Tokens.Ink.primary)
                Text(version).foregroundStyle(Tokens.Ink.tertiary)
            }
            .typo(Tokens.Typography.Label.smMedium)
            .padding(.leading, 10)

            Spacer(minLength: 8)
            IconButton(systemName: "arrow.up.right", iconSize: 13, action: onOpenWindow)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var primary: some View {
        switch status {
        case .idle:
            MenuRow(title: "Записать", action: onStartRecording)
        case .recording(let title, let elapsed):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    stopButton
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).foregroundStyle(Tokens.Ink.primary).lineLimit(1)
                        Text(elapsed).foregroundStyle(Tokens.Ink.tertiary).monospacedDigit()
                    }
                    .typo(Tokens.Typography.Label.smMedium)
                    Spacer(minLength: 0)
                }
                if onDiscard != nil {
                    MenuRow(title: "Стоп и сбросить", action: { onDiscard?() })
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
        case .processing(let text):
            Text(text)
                .typo(Tokens.Typography.Label.smMedium)
                .foregroundStyle(Tokens.Ink.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)   // sm
                .background(Color(nsColor: .systemRed), in: Circle())   // system destructive colour
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // 8px row with a centred hairline, inset to align with the row text.
    private var divider: some View {
        Color.clear.frame(height: 8).overlay(
            Rectangle().fill(Tokens.Neutral.aw10).frame(height: 1).padding(.horizontal, 10)
        )
    }
}

/// A popover menu row: SF Pro Medium 12, hover fills a 6pt rounded highlight.
///
/// Optional `symbol` / `shortcut` follow the system menu layout — icon, title,
/// then the key equivalent on the trailing edge (same as `Menu` + `Label` +
/// `keyboardShortcut`, drawn by hand because this is a custom panel).
private struct MenuRow: View {
    let title: String
    var symbol: String? = nil
    var shortcut: String? = nil
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Tokens.Ink.primary)
                        .frame(width: 16, alignment: .center)
                }
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
        MenuBarPopover(status: .idle, onOpenWindow: {}, onStartRecording: {}, onStop: {},
                       onSettings: {}, onQuit: {})
        MenuBarPopover(status: .recording(title: "Новая запись 26.08", elapsed: "00:12:04"),
                       onOpenWindow: {}, onStartRecording: {}, onStop: {},
                       onSettings: {}, onQuit: {})
        MenuBarPopover(status: .processing("Сохранение…"), onOpenWindow: {}, onStartRecording: {},
                       onStop: {}, onSettings: {}, onQuit: {})
    }
    .padding(40)
    .background(Color(white: 0.12))
}
