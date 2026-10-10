import UserNotifications
import VictualHealth

/// Local notifications for refill notices, through the system.
///
/// Alert only: no sound and no badge. The text is fixed by
/// ``RefillNotificationContent`` and names nothing, because it shows on a locked screen.
struct SystemRefillNotificationCenter: RefillNotificationCenter {
    private var center: UNUserNotificationCenter { .current() }

    func isAuthorized() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert])) ?? false
    }

    func post(identifier: String, title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "dev.victual.refill"
        content.interruptionLevel = .passive
        // No trigger: delivered now. The identifier is the notice key, so a repeat replaces.
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func remove(identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removeAll() async {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
