import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import EventKit
import ServiceManagement
import ApplicationServices
import UserNotifications
import PropellerUI

/// Hosts `OnboardingFlowView` and wires steps to the app: name → Preferences,
/// calendar → EventKit, grants → TCC prompts, launch-at-login → SMAppService.
///
/// Every row reflects a *real* authorization state, polled once a second so the
/// tick appears as soon as the user grants it in System Settings.
struct OnboardingContainer: View {
    @ObservedObject var state: AppState

    @State private var microphoneGranted = false
    @State private var systemAudioGranted = false
    @State private var notificationsGranted = false
    @State private var calendarGranted = false
    @State private var ollamaReady = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        OnboardingFlowView(
            onComplete: { name in
                Preferences.shared.userName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                Preferences.shared.onboardingCompleted = true
                // System audio capture is required for remote speakers — lock it on
                // once Screen Recording was granted in onboarding.
                Preferences.shared.captureSystemAudio = true
                state.showOnboarding = false
                Analytics.signal("Onboarding.completed")
            },
            microphoneGranted: microphoneGranted,
            systemAudioGranted: systemAudioGranted,
            notificationsGranted: notificationsGranted,
            calendarGranted: calendarGranted,
            onConnectCalendar: { provider in
                // Google calendars reach us through macOS, not OAuth: the account
                // has to exist in System Settings → Internet Accounts first.
                if provider == .google, !calendarGranted {
                    openInternetAccounts()
                }
                Preferences.shared.calendarEnabled = true
                Task {
                    await CalendarService.shared.enableAndLoad()
                    await MainActor.run { refreshGrants() }
                }
            },
            onGrantMicrophone: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .notDetermined:
                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                case .denied, .restricted:
                    openSettings("Privacy_Microphone")
                default:
                    break
                }
            },
            onGrantSystemAudio: {
                // First call shows the system prompt; if previously denied, open Settings.
                if CGPreflightScreenCaptureAccess() { return }
                if !CGRequestScreenCaptureAccess() {
                    openSettings("Privacy_ScreenCapture")
                }
            },
            onGrantNotifications: {
                let center = UNUserNotificationCenter.current()
                center.getNotificationSettings { settings in
                    switch settings.authorizationStatus {
                    case .notDetermined:
                        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
                    case .denied:
                        DispatchQueue.main.async { openNotificationSettings() }
                    default:
                        break
                    }
                }
            },
            onSetLaunchAtLogin: { on in
                do {
                    if on { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch { NSLog("[Onboarding] launch-at-login failed: \(error)") }
            },
            onDownloadSummaryModel: {
                state.startOllamaRuntimeDownload()
            },
            ollamaProgress: state.ollamaSetupProgress,
            ollamaStatus: state.ollamaSetupMessage,
            ollamaReady: ollamaReady,
            ollamaError: state.ollamaSetupError
        )
        .onAppear {
            refreshGrants()
            Task {
                let model = Preferences.shared.recapOllamaModel
                let name = model.isEmpty ? OllamaSidecar.defaultModel : model
                if await OllamaSidecar.shared.probeAPI(),
                   await OllamaSidecar.shared.modelPresent(name) {
                    await MainActor.run { ollamaReady = true }
                }
            }
        }
        .onChange(of: state.ollamaSetupMessage) { _, msg in
            if msg == "Модель готова" { ollamaReady = true }
        }
        .onReceive(poll) { _ in refreshGrants() }
    }

    private func refreshGrants() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        systemAudioGranted = CGPreflightScreenCaptureAccess()
        calendarGranted = Self.calendarAuthorized

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                if notificationsGranted != granted { notificationsGranted = granted }
            }
        }
    }

    /// Package targets macOS 14+, so full access is the only state that counts.
    private static var calendarAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    private func openSettings(_ anchor: String) {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    private func openNotificationSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.notifications")
    }

    /// System Settings → Internet Accounts, where a Google account is added.
    private func openInternetAccounts() {
        openSystemSettings("x-apple.systempreferences:com.apple.preferences.internetaccounts")
    }

    /// Always go through the panel controller: the onboarding plate floats above
    /// ordinary windows, so System Settings would open behind it and the grant
    /// button would look dead.
    private func openSystemSettings(_ string: String) {
        guard let url = URL(string: string) else { return }
        OnboardingPanelController.shared.yieldToSystemWindow()
        NSWorkspace.shared.open(url)
    }
}
