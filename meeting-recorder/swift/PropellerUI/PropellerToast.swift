import SwiftUI

/// In-app toast — Figma 640:1987.
///
/// Always: title + subtitle (≤2 lines) + dismiss ✕.
/// Buttons: none, one, or two. When two: primary = filled pill, secondary = plain text.
public struct PropellerToast: View {
    public let title: String
    public let subtitle: String
    public var primary: ToastButton? = nil
    public var secondary: ToastButton? = nil
    public var onDismiss: () -> Void

    public struct ToastButton {
        public let title: String
        public let action: () -> Void
        public init(_ title: String, action: @escaping () -> Void) {
            self.title = title
            self.action = action
        }
    }

    public init(
        title: String,
        subtitle: String,
        primary: ToastButton? = nil,
        secondary: ToastButton? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.primary = primary
        self.secondary = secondary
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.Ink.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Tokens.Ink.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 16)

            if primary != nil || secondary != nil {
                HStack(spacing: 6) {
                    if let primary {
                        toastPill(primary)
                    }
                    if let secondary {
                        toastPlain(secondary)
                    }
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 32)
        .padding(.vertical, 12)
        .frame(maxWidth: Tokens.Toast.maxWidth, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Toast.radius, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: Tokens.Toast.radius, style: .continuous)
                .fill(Tokens.Toast.fill)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Закрыть")
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
    }

    private func toastPill(_ button: ToastButton) -> some View {
        Button(action: button.action) {
            Text(button.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.Ink.primary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.white.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toastPlain(_ button: ToastButton) -> some View {
        Button(action: button.action) {
            Text(button.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.Ink.primary)
                .padding(.horizontal, 10)
                .frame(height: 32)
        }
        .buttonStyle(.plain)
    }
}
