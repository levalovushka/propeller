import SwiftUI
import AppKit
import AVFoundation
import ServiceManagement
import UserNotifications
import PropellerUI

/// Hosts `SetupView` and wires it to the machine: grants → TCC prompts,
/// launch-at-login → `SMAppService`, «Начать» → the app.
///
/// Both permission rows reflect a *real* authorization state, polled once a
/// second so the tick appears the moment it is granted in System Settings rather
/// than when the plate happens to redraw.
struct OnboardingContainer: View {
    @ObservedObject var state: AppState

    @State private var microphoneGranted = false
    @State private var notificationsGranted = false
    @State private var launchAtLogin = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SetupView(
            microphoneGranted: microphoneGranted,
            notificationsGranted: notificationsGranted,
            launchAtLogin: launchAtLogin,
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
            onGrantNotifications: {
                // The prompt is `NotificationManager`'s to spend, and this row is
                // the only thing that spends it — bootstrap deliberately no longer
                // asks, so the one prompt macOS gives us is still here to give.
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    switch settings.authorizationStatus {
                    case .notDetermined:
                        NotificationManager.shared.requestAuthorization { refreshGrants() }
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
                    launchAtLogin = on
                } catch {
                    NSLog("[Setup] launch-at-login failed: \(error)")
                    // Say what is true: the switch goes back, because the login
                    // item did not take.
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            },
            onStart: finish
        )
        .onAppear {
            refreshGrants()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .onReceive(poll) { _ in refreshGrants() }
    }

    /// The only way off the plate.
    ///
    /// The summary model starts downloading here — on the press, not on the
    /// screen appearing — and nothing on screen says so. It is ~3.4 GB the app
    /// needs and nobody has to decide about (`design/no-dead-ends.md` §5):
    /// recording and transcription work immediately, summaries backfill when the
    /// weights land. A progress bar here would be an invitation to wait for
    /// something there is no reason to wait for.
    ///
    /// The name is *not* written. It is the rail's question now
    /// (`SetupPromptMachine`), and an empty `userName` is what tells the rail it
    /// still has to ask — writing `NSFullUserName()` here as a fallback would
    /// answer the question on the user's behalf and the block would never appear.
    /// The fallback lives at the point of use instead (`Preferences.ownerName`).
    private func finish() {
        Preferences.shared.onboardingCompleted = true
        // Remote speakers come from the process tap, which needs no grant of its
        // own — the switch stays on because there is nothing to switch off.
        Preferences.shared.captureSystemAudio = true
        state.showOnboarding = false
        Task { await state.ensureSummaryModel() }
        Analytics.signal("Onboarding.completed")
    }

    private func refreshGrants() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                if notificationsGranted != granted { notificationsGranted = granted }
            }
        }
    }

    private func openSettings(_ anchor: String) {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    private func openNotificationSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.notifications")
    }

    /// Always go through the panel controller: the setup plate floats above
    /// ordinary windows, so System Settings would open behind it and the grant
    /// button would look dead.
    private func openSystemSettings(_ string: String) {
        guard let url = URL(string: string) else { return }
        OnboardingPanelController.shared.yieldToSystemWindow()
        NSWorkspace.shared.open(url)
    }
}
