import SwiftUI

/// Welcome → Name → Calendar → Permissions → End.
/// Glass lives on the host window (not per-step).
public struct OnboardingFlowView: View {
    var onComplete: (String) -> Void
    var microphoneGranted: Bool
    var systemAudioGranted: Bool
    var notesGranted: Bool
    var onConnectCalendar: () -> Void
    var onGrantMicrophone: () -> Void
    var onGrantSystemAudio: () -> Void
    var onGrantNotes: () -> Void
    var onSetLaunchAtLogin: (Bool) -> Void

    public init(
        onComplete: @escaping (String) -> Void,
        microphoneGranted: Bool = false,
        systemAudioGranted: Bool = false,
        notesGranted: Bool = false,
        onConnectCalendar: @escaping () -> Void = {},
        onGrantMicrophone: @escaping () -> Void = {},
        onGrantSystemAudio: @escaping () -> Void = {},
        onGrantNotes: @escaping () -> Void = {},
        onSetLaunchAtLogin: @escaping (Bool) -> Void = { _ in }
    ) {
        self.onComplete = onComplete
        self.microphoneGranted = microphoneGranted
        self.systemAudioGranted = systemAudioGranted
        self.notesGranted = notesGranted
        self.onConnectCalendar = onConnectCalendar
        self.onGrantMicrophone = onGrantMicrophone
        self.onGrantSystemAudio = onGrantSystemAudio
        self.onGrantNotes = onGrantNotes
        self.onSetLaunchAtLogin = onSetLaunchAtLogin
    }

    private enum Step { case welcome, name, calendar, permissions, end }
    @State private var step: Step = .welcome
    @State private var name = ""

    public var body: some View {
        Group {
            switch step {
            case .welcome:
                OnboardingWelcomeView(onSetUp: { go(.name) }, onSkip: { go(.name) })
            case .name:
                OnboardingNameView(onNext: { name = $0; go(.calendar) },
                                   onBack: { go(.welcome) })
            case .calendar:
                OnboardingCalendarView(onNext: { go(.permissions) },
                                       onSkip: { go(.permissions) },
                                       onBack: { go(.name) },
                                       onConnect: { _ in onConnectCalendar() })
            case .permissions:
                OnboardingPermissionsView(onNext: { go(.end) },
                                          onBack: { go(.calendar) },
                                          microphoneGranted: microphoneGranted,
                                          systemAudioGranted: systemAudioGranted,
                                          notesGranted: notesGranted,
                                          onGrantMicrophone: onGrantMicrophone,
                                          onGrantSystemAudio: onGrantSystemAudio,
                                          onGrantNotes: onGrantNotes,
                                          onSetLaunchAtLogin: onSetLaunchAtLogin)
            case .end:
                OnboardingEndView(onFinish: { onComplete(name) })
            }
        }
    }

    private func go(_ next: Step) {
        step = next
    }
}

#Preview("Onboarding flow") {
    OnboardingFlowView(onComplete: { _ in })
        .background(GlassBackground())
}
