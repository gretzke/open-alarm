import AlarmKit
import UIKit
import UserNotifications

final class OpenAlarmNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        Task { @MainActor in
            WakeUpCheckNotificationService().ensureCategoryRegistered()
        }

        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.content.categoryIdentifier == WakeUpCheckNotificationConstants.categoryID {
            enqueueConfirmationUI(from: notification.request.content.userInfo)
            completionHandler([])
            return
        }

        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard response.notification.request.content.categoryIdentifier == WakeUpCheckNotificationConstants.categoryID else {
            return
        }

        enqueueConfirmationUI(from: response.notification.request.content.userInfo)
    }

    private func enqueueConfirmationUI(from userInfo: [AnyHashable: Any]) {
        guard let rawAlarmID = userInfo[WakeUpCheckNotificationConstants.alarmIDUserInfoKey] as? String,
              let alarmID = UUID(uuidString: rawAlarmID) else {
            return
        }

        let persistence = AlarmPersistence.shared
        var pendingIDs = persistence.loadPendingWakeUpCheckShowConfirmUIIDs()
        pendingIDs.insert(alarmID)
        persistence.savePendingWakeUpCheckShowConfirmUIIDs(pendingIDs)

        NotificationCenter.default.post(name: .wakeUpCheckConfirmationRequested, object: nil)
    }
}
