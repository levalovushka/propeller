import SwiftUI

/// Permissions step — Figma 642:2291. Centred cells; Next unlocks when ready.
///
/// Deliberately minimal: only what the first recording actually needs.
/// Mic + system audio (Screen Recording) are required — mic alone loses every
/// remote speaker. Notifications are how the user declines an auto-started Zoom
/// recording («Не записывать»), so they are asked here rather than silently at
/// launch. Accessibility for the ⌃⌥N notes overlay is **not** asked here: it is
/// deferred to a just-in-time toast on first recording, to keep the start-up
/// permission count down (decision 2026-07-25).
///
/// Four rows (title 14 medium + subtitle 12 regular, padding 4, divider 16)
/// ≈ 224pt of the ~276pt available on the 400pt card. Adding a row means
/// re-checking that budget.
struct OnboardingPermissionsView: View {
    var onNext: () -> Void
    var onBack: () -> Void
    var microphoneGranted: Bool = false
    var systemAudioGranted: Bool = false
    var notificationsGranted: Bool = false
    var onGrantMicrophone: () -> Void = {}
    var onGrantSystemAudio: () -> Void = {}
    var onGrantNotifications: () -> Void = {}
    var onSetLaunchAtLogin: (Bool) -> Void = { _ in }

    @State private var launchAtLogin = false

    /// Both sides of the call — mic alone is not enough for remote speakers.
    private var canProceed: Bool { microphoneGranted && systemAudioGranted }

    /// Fixed control column so the row doesn't shift when a pill becomes a tick.
    private let controlWidth: CGFloat = 104

    var body: some View {
        OnboardingCard {
            OnboardingBackButton(action: onBack)
        } content: {
            VStack(spacing: 0) {
                cell("Микрофон", "Ваш голос в звонке") {
                    grantControl(granted: microphoneGranted, action: onGrantMicrophone)
                }
                divider
                cell("Звук системы", "Собеседники в Zoom") {
                    grantControl(granted: systemAudioGranted, action: onGrantSystemAudio)
                }
                divider
                cell("Уведомления", "Чтобы отказаться от записи") {
                    grantControl(granted: notificationsGranted, action: onGrantNotifications)
                }
                divider
                cell("Запуск при входе", "Готов к встрече без вас") {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                        .tint(Color.accentColor)
                        .onChange(of: launchAtLogin) { _, on in onSetLaunchAtLogin(on) }
                        .frame(width: controlWidth, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } actions: {
            HStack {
                nextButton
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var nextButton: some View {
        if canProceed {
            PillButton(title: "Далее", kind: .primary, action: onNext)
        } else {
            Text("Далее")
                .font(.pillLabel)
                .foregroundStyle(Tokens.Ink.tertiary)
                .padding(.horizontal, Tokens.Pill.hPadding)
                .padding(.vertical, Tokens.Pill.vPadding)
                .frame(height: Tokens.Pill.height)
                .background(Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: Tokens.Pill.radius, style: .continuous))
        }
    }

    private func cell<Control: View>(
        _ title: String, _ subtitle: String, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Tokens.Ink.primary)
                Text(subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Tokens.Ink.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func grantControl(granted: Bool, action: @escaping () -> Void) -> some View {
        if granted {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.Ink.secondary)
                .frame(width: controlWidth, height: Tokens.Pill.height, alignment: .trailing)
        } else {
            PillButton(title: "Разрешить", kind: .secondary, size: .sm, action: action)
                .frame(width: controlWidth, alignment: .trailing)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).frame(height: 16)
    }
}

#Preview("Permissions") {
    OnboardingPermissionsView(onNext: {}, onBack: {})
        .background(GlassBackground())
}
