import Foundation
import UserNotifications

/// Owns user-notification setup for the app: authorization, the interactive
/// "recording started" notification, and its "Don't record" action.
///
/// Must be an NSObject because `UNUserNotificationCenterDelegate` is an
/// Objective-C protocol. AppState wires `onCancelRecording` at bootstrap so
/// tapping the action cancels the in-progress recording.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// Invoked on the main actor when the user taps "Don't record".
    var onCancelRecording: (() -> Void)?

    static let meetingCategory = "MEETING_RECORDING"
    static let cancelAction = "CANCEL_RECORDING"
    /// Fixed identifier so the notification can be cleared once recording stops.
    static let recordingNotificationID = "meeting-recording"

    /// Last known authorization, kept so `PushPolicy` can be asked a synchronous
    /// question. `getNotificationSettings` is async, and a policy that had to
    /// await it would have to be called from somewhere that can — which is how
    /// «слать или нет» ended up decided at nine different call sites.
    private(set) var isAuthorized = false

    private override init() { super.init() }

    /// Request authorization, register the delegate, and install the
    /// interactive category. Call once at app startup.
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.isAuthorized = granted
        }

        let cancel = UNNotificationAction(
            identifier: Self.cancelAction,
            title: "Не записывать",
            options: [.destructive, .foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.meetingCategory,
            actions: [cancel],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Post the actionable "recording started automatically" notification.
    /// `authorized` reports whether notifications can show the decline action.
    func notifyRecordingStarted(completion: ((Bool) -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            let ok = settings.authorizationStatus == .authorized
            self?.isAuthorized = ok
            guard ok else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Propeller записывает встречу"
            content.body = "Запись началась автоматически. Нажмите «Не записывать», чтобы отменить."
            content.categoryIdentifier = Self.meetingCategory
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: Self.recordingNotificationID,
                content: content,
                trigger: nil
            )
            center.add(request) { _ in
                DispatchQueue.main.async { completion?(true) }
            }
        }
    }

    /// Remove the delivered "recording started" notification (once recording
    /// stops normally or is cancelled) so its stale action doesn't linger.
    func clearRecordingNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.recordingNotificationID])
    }

    /// Fire-and-forget status banner.
    ///
    /// Whether this is called at all — and whether it makes a sound — is decided
    /// by `PushPolicy`, not here and not at the call site. Silence is the default:
    /// only an alarm gets a sound, and never while a recording is running
    /// (`design/notifications.md`, R7).
    func post(title: String, body: String, sound: Bool = false) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            let ok = settings.authorizationStatus == .authorized
            self?.isAuthorized = ok
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if sound { content.sound = .default }
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners even while the app is frontmost — and carry the sound only
    /// when the notification was given one. Asking for `.sound` unconditionally
    /// made the decision here instead of in the policy.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        var options: UNNotificationPresentationOptions = [.banner]
        if notification.request.content.sound != nil { options.insert(.sound) }
        completionHandler(options)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == Self.cancelAction {
            Task { @MainActor in self.onCancelRecording?() }
        }
        completionHandler()
    }
}
