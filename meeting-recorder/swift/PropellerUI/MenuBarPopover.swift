import SwiftUI
import AppKit

/// The menu-bar popover: a small glass panel with a header (name + version +
/// open-window), a state-dependent primary row, and Settings / Restart / Quit.
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
    var onSettings: () -> Void
    var onRestart: () -> Void
    var onQuit: () -> Void

    public init(
        version: String = "v0.1 Beta",
        status: Status,
        onOpenWindow: @escaping () -> Void,
        onStartRecording: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onRestart: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.version = version
        self.status = status
        self.onOpenWindow = onOpenWindow
        self.onStartRecording = onStartRecording
        self.onStop = onStop
        self.onSettings = onSettings
        self.onRestart = onRestart
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            divider
            primary
            divider
            MenuRow(title: "Settings", action: onSettings)
            MenuRow(title: "Restart", action: onRestart)
            MenuRow(title: "Quit", action: onQuit)
        }
        .padding(6)
        .frame(width: 260)
        .background(GlassBackground(material: .regularMaterial, tinted: false))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Propeller").foregroundStyle(Tokens.Ink.primary)
                Text(version).foregroundStyle(Tokens.Ink.tertiary)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.leading, 10)

            Spacer(minLength: 8)
            IconButton(systemName: "arrow.up.right", iconSize: 13, action: onOpenWindow)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var primary: some View {
        switch status {
        case .idle:
            MenuRow(title: "Start recording", action: onStartRecording)
        case .recording(let title, let elapsed):
            HStack(spacing: 8) {
                stopButton
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).foregroundStyle(Tokens.Ink.primary).lineLimit(1)
                    Text(elapsed).foregroundStyle(Tokens.Ink.tertiary).monospacedDigit()
                }
                .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
        case .processing(let text):
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Tokens.Ink.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .semibold))
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
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).padding(.horizontal, 10)
        )
    }
}

/// A popover menu row: SF Pro Medium 12, hover fills a 6pt rounded highlight.
private struct MenuRow: View {
    let title: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Tokens.Ink.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(hovering ? 0.07 : 0),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

#Preview("Popover states") {
    HStack(alignment: .top, spacing: 24) {
        MenuBarPopover(status: .idle, onOpenWindow: {}, onStartRecording: {}, onStop: {},
                       onSettings: {}, onRestart: {}, onQuit: {})
        MenuBarPopover(status: .recording(title: "New recording 26.08", elapsed: "00:12:04"),
                       onOpenWindow: {}, onStartRecording: {}, onStop: {},
                       onSettings: {}, onRestart: {}, onQuit: {})
        MenuBarPopover(status: .processing("Saving…"), onOpenWindow: {}, onStartRecording: {},
                       onStop: {}, onSettings: {}, onRestart: {}, onQuit: {})
    }
    .padding(40)
    .background(Color(white: 0.12))
}
