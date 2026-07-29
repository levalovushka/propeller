import SwiftUI

/// Permissions step — Figma 642:2291. Centred cells; Next unlocks when ready.
///
/// Deliberately minimal: only what the first recording actually needs.
///
/// **Запись экрана здесь больше не спрашивается (2026-07-29).** Она стояла тут
/// под именем «Звук системы» и блокировала кнопку «Далее», потому что звук
/// собеседников снимался через ScreenCaptureKit. Теперь его снимает тап на
/// процессы, которому это разрешение не нужно вовсе; сам захват звука система
/// спросит одним своим диалогом при первом запуске. Шаг был самым дорогим в
/// онбординге — он требовал перезапуска приложения.
///
/// Микрофон остался единственным обязательным: без него записывать нечего.
/// Уведомления — то, чем человек отказывается от авто-записи («Не записывать»),
/// поэтому спрашиваются здесь, а не молча при запуске. Accessibility для ⌃⌥N
/// **не** спрашивается: отложено до тоста в момент первой записи (2026-07-25).
///
/// Три ряда (title 14 medium + subtitle 12 regular, padding 4, divider 16)
/// ≈ 168pt из ~276pt на карточке 400pt. Добавляя ряд, пересчитайте бюджет.
struct OnboardingPermissionsView: View {
    var onNext: () -> Void
    var onBack: () -> Void
    var microphoneGranted: Bool = false
    var notificationsGranted: Bool = false
    var onGrantMicrophone: () -> Void = {}
    var onGrantNotifications: () -> Void = {}
    var onSetLaunchAtLogin: (Bool) -> Void = { _ in }

    @State private var launchAtLogin = false

    /// Микрофон — единственное, без чего записывать нечего. Дальняя сторона
    /// зависит от разрешения на захват звука, а его статус спросить нечем
    /// (API нет), так что блокировать им кнопку было бы гаданием.
    private var canProceed: Bool { microphoneGranted }

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
                .typo(Tokens.Typography.Label.pill)
                .foregroundStyle(Tokens.Ink.tertiary)
                .padding(.horizontal, Tokens.Pill.hPadding)
                .padding(.vertical, Tokens.Pill.vPadding)
                .frame(height: Tokens.Pill.height)
                .background(Tokens.Paint.Bg.surface,
                            in: RoundedRectangle(cornerRadius: Tokens.Pill.radius, style: .continuous))
        }
    }

    private func cell<Control: View>(
        _ title: String, _ subtitle: String, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .typo(Tokens.Typography.Label.mdMedium)
                    .foregroundStyle(Tokens.Ink.primary)
                Text(subtitle)
                    .typo(Tokens.Typography.Label.smRegular)
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
        Rectangle().fill(Tokens.Neutral.aw10).frame(height: 1).frame(height: 16)
    }
}

#Preview("Permissions") {
    OnboardingPermissionsView(onNext: {}, onBack: {})
        .background(GlassBackground())
}
