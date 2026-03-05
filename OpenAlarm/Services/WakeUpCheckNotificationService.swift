import Foundation
import UserNotifications

@MainActor
final class WakeUpCheckNotificationService {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func ensureCategoryRegistered() {
        let confirmAction = UNNotificationAction(
            identifier: WakeUpCheckAction.confirmAwake.rawValue,
            title: String(localized: "wake_check_notification_action_awake"),
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: WakeUpCheckNotificationConstants.categoryID,
            actions: [confirmAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([category])
    }

    func scheduleWakeCheckNotification(for session: WakeUpCheckSessionState) async throws {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "wake_check_notification_title")
        content.body = String(localized: "wake_check_notification_body")
        content.sound = .default
        content.categoryIdentifier = WakeUpCheckNotificationConstants.categoryID
        content.userInfo = [
            WakeUpCheckNotificationConstants.alarmIDUserInfoKey: session.alarmID.uuidString,
            WakeUpCheckNotificationConstants.cycleUserInfoKey: session.cycle
        ]

        let fireIn = max(1, Int(session.checkAt.timeIntervalSinceNow.rounded(.up)))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(fireIn), repeats: false)
        let request = UNNotificationRequest(
            identifier: session.notificationID,
            content: content,
            trigger: trigger
        )

        try await center.add(request)
    }

    func cancel(notificationID: String) {
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [notificationID])
    }

}
