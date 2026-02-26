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
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard response.actionIdentifier == WakeUpCheckAction.confirmAwake.rawValue else {
            return
        }

        guard let rawAlarmID = response.notification.request.content.userInfo[WakeUpCheckNotificationConstants.alarmIDUserInfoKey] as? String,
              let alarmID = UUID(uuidString: rawAlarmID) else {
            return
        }

        var pending = AlarmPersistence.loadPendingWakeUpCheckConfirmIDs()
        pending.insert(alarmID)
        AlarmPersistence.savePendingWakeUpCheckConfirmIDs(pending)
    }
}
