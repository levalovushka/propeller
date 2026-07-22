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

    private override init() { super.init() }

    /// Request authorization, register the delegate, and install the
    /// interactive category. Call once at app startup.
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

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
    func notifyRecordingStarted() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
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
            center.add(request)
        }
    }

    /// Remove the delivered "recording started" notification (once recording
    /// stops normally or is cancelled) so its stale action doesn't linger.
    func clearRecordingNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.recordingNotificationID])
    }

    /// Fire-and-forget status banner (saved / stopped / recap ready, etc.).
    func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners even while the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
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
