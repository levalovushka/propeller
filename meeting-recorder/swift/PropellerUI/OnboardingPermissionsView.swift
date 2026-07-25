import SwiftUI

/// Permissions step — Figma 642:2291. Centred title + cells; Next when ready.
/// Mic + system audio (Screen Recording) are required; Accessibility / login are optional.
struct OnboardingPermissionsView: View {
    var onNext: () -> Void
    var onBack: () -> Void
    var microphoneGranted: Bool = false
    var systemAudioGranted: Bool = false
    var notesGranted: Bool = false
    var onGrantMicrophone: () -> Void = {}
    var onGrantSystemAudio: () -> Void = {}
    var onGrantNotes: () -> Void = {}
    var onSetLaunchAtLogin: (Bool) -> Void = { _ in }

    @State private var launchAtLogin = false

    /// Both sides of the call — mic alone is not enough for remote speakers.
    private var canProceed: Bool { microphoneGranted && systemAudioGranted }

    var body: some View {
        OnboardingCard {
            OnboardingBackButton(action: onBack)
        } content: {
            VStack(spacing: 0) {
                cell("Microphone", "Your side of the call") {
                    grantControl(granted: microphoneGranted, action: onGrantMicrophone)
                }
                divider
                cell("System audio", "Remote speakers from Zoom and meetings") {
                    grantControl(granted: systemAudioGranted, action: onGrantSystemAudio)
                }
                divider
                cell("Notes over any app", "So your hotkey notes land over Zoom") {
                    grantControl(granted: notesGranted, action: onGrantNotes)
                }
                divider
                cell("Launch at login", "Ready for the meeting without you") {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                        .tint(Color.accentColor)
                        .onChange(of: launchAtLogin) { _, on in onSetLaunchAtLogin(on) }
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
            PillButton(title: "Next", kind: .primary, action: onNext)
        } else {
            Text("Next")
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
                Text(title).foregroundStyle(Tokens.Ink.primary)
                Text(subtitle).foregroundStyle(Tokens.Ink.tertiary)
            }
            .font(.system(size: 14, weight: .medium))
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private func grantControl(granted: Bool, action: @escaping () -> Void) -> some View {
        if granted {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.Ink.secondary)
                .frame(width: 68, height: Tokens.Pill.height, alignment: .trailing)
        } else {
            PillButton(title: "Grant", kind: .secondary, size: .sm, action: action)
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
