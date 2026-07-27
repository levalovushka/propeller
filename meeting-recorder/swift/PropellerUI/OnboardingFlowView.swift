import SwiftUI
import AppKit

/// Welcome → Name → Calendar → Permissions → Summary model → End.
/// Glass lives on the host window (not per-step).
///
/// "Пропустить" on the welcome carousel skips the *tour*, not the setup: it
/// jumps to permissions, which stay mandatory (mic + system audio). The name
/// defaults to the macOS full name so a skipped name step never leaves the
/// owner-by-mic labelling without a name.
public struct OnboardingFlowView: View {
    var onComplete: (String) -> Void
    var microphoneGranted: Bool
    var systemAudioGranted: Bool
    var notificationsGranted: Bool
    var calendarGranted: Bool
    var onConnectCalendar: (CalendarProvider) -> Void
    var onGrantMicrophone: () -> Void
    var onGrantSystemAudio: () -> Void
    var onGrantNotifications: () -> Void
    var onSetLaunchAtLogin: (Bool) -> Void
    var onDownloadSummaryModel: () -> Void
    var ollamaProgress: Double?
    var ollamaStatus: String
    var ollamaReady: Bool
    var ollamaError: String?

    public init(
        onComplete: @escaping (String) -> Void,
        microphoneGranted: Bool = false,
        systemAudioGranted: Bool = false,
        notificationsGranted: Bool = false,
        calendarGranted: Bool = false,
        onConnectCalendar: @escaping (CalendarProvider) -> Void = { _ in },
        onGrantMicrophone: @escaping () -> Void = {},
        onGrantSystemAudio: @escaping () -> Void = {},
        onGrantNotifications: @escaping () -> Void = {},
        onSetLaunchAtLogin: @escaping (Bool) -> Void = { _ in },
        onDownloadSummaryModel: @escaping () -> Void = {},
        ollamaProgress: Double? = nil,
        ollamaStatus: String = "",
        ollamaReady: Bool = false,
        ollamaError: String? = nil
    ) {
        self.onComplete = onComplete
        self.microphoneGranted = microphoneGranted
        self.systemAudioGranted = systemAudioGranted
        self.notificationsGranted = notificationsGranted
        self.calendarGranted = calendarGranted
        self.onConnectCalendar = onConnectCalendar
        self.onGrantMicrophone = onGrantMicrophone
        self.onGrantSystemAudio = onGrantSystemAudio
        self.onGrantNotifications = onGrantNotifications
        self.onSetLaunchAtLogin = onSetLaunchAtLogin
        self.onDownloadSummaryModel = onDownloadSummaryModel
        self.ollamaProgress = ollamaProgress
        self.ollamaStatus = ollamaStatus
        self.ollamaReady = ollamaReady
        self.ollamaError = ollamaError
    }

    private enum Step { case welcome, name, calendar, permissions, summaryModel, end }
    @State private var step: Step = .welcome
    @State private var name = NSFullUserName()
    @State private var summarySkipped = false

    public var body: some View {
        Group {
            switch step {
            case .welcome:
                OnboardingWelcomeView(onSetUp: { go(.name) },
                                      onSkip: { go(.permissions) })
            case .name:
                OnboardingNameView(onNext: { name = $0; go(.calendar) },
                                   onBack: { go(.welcome) })
            case .calendar:
                OnboardingCalendarView(onNext: { go(.permissions) },
                                       onSkip: { go(.permissions) },
                                       onBack: { go(.name) },
                                       calendarGranted: calendarGranted,
                                       onConnect: onConnectCalendar)
            case .permissions:
                OnboardingPermissionsView(onNext: { go(.summaryModel) },
                                          onBack: { go(.calendar) },
                                          microphoneGranted: microphoneGranted,
                                          systemAudioGranted: systemAudioGranted,
                                          notificationsGranted: notificationsGranted,
                                          onGrantMicrophone: onGrantMicrophone,
                                          onGrantSystemAudio: onGrantSystemAudio,
                                          onGrantNotifications: onGrantNotifications,
                                          onSetLaunchAtLogin: onSetLaunchAtLogin)
            case .summaryModel:
                OnboardingSummaryModelView(
                    onNext: { go(.end) },
                    onSkip: {
                        summarySkipped = true
                        go(.end)
                    },
                    onBack: { go(.permissions) },
                    onStartDownload: onDownloadSummaryModel,
                    isReady: ollamaReady,
                    errorMessage: ollamaError
                )
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
