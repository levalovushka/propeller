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
    @State private var accessibilityGranted = false
    /// AX has no `.notDetermined` to read: the first press shows the system
    /// prompt, and every press after a refusal routes to System Settings —
    /// the same door the microphone row opens after a refusal.
    @State private var accessibilityPromptShown = false
    @State private var notificationsGranted = false
    @State private var launchAtLogin = false
    /// Прогрев захвата платится один раз за показ плиты. Опрос идёт раз в
    /// секунду, а неудавшийся прогрев не запоминается как «готово», так что без
    /// этого флага отказавший путь открывал бы микрофон каждую секунду.
    @State private var warmUpStarted = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SetupView(
            microphoneGranted: microphoneGranted,
            accessibilityGranted: accessibilityGranted,
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
            onGrantAccessibility: {
                // The dialogue, never the list: adding the app by hand failed
                // twice on the machine this was measured on — only
                // `AXIsProcessTrustedWithOptions` reliably seats the grant
                // (plan-speaker-tags.md §6). The grant may land only after a
                // relaunch; the polled tick simply appears when it is true.
                if accessibilityPromptShown {
                    openSettings("Privacy_Accessibility")
                } else {
                    accessibilityPromptShown = true
                    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
                    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
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
        // Захват системного звука здесь больше не включают: он не выключается
        // (`Preferences.captureSystemAudio`).
        state.showOnboarding = false
        Task { await state.ensureSummaryModel() }
        Analytics.signal("Onboarding.completed")
    }

    private func refreshGrants() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        warmUpCaptureIfGranted()

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                if notificationsGranted != granted { notificationsGranted = granted }
            }
        }
    }

    /// Заплатить за первое открытие входа Core Audio здесь — на плите, после
    /// того как разрешение пришло.
    ///
    /// Раньше это делалось на запуске приложения (`AppDelegate`), и именно оно
    /// показывало системный запрос микрофона до всякого нажатия. Теперь прогрев
    /// ждёт разрешения (`ProcessTapCapture.warmUpIfNeeded`), а разрешение
    /// приходит здесь — на «Разрешить» или из системных настроек, куда ведёт та
    /// же кнопка после отказа. Обе двери сходятся в опросе, поэтому ловим факт
    /// выданного разрешения, а не нажатие.
    ///
    /// Время до первой записи от этого не страдает: до неё ещё как минимум
    /// «Дальше», и минута прогрева идёт в фоне, пока плита стоит.
    private func warmUpCaptureIfGranted() {
        guard microphoneGranted, !warmUpStarted else { return }
        guard Preferences.shared.captureSystemAudio else { return }
        warmUpStarted = true
        Task.detached(priority: .utility) {
            await ProcessTapCapture.warmUpIfNeeded()
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
