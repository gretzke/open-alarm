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

        // TODO(wake-check-phase2): Replace this direct "confirm awake" enqueue with an
        // app-driven challenge completion handoff once challenge UI is implemented.
        //
        // Why this still writes only durable queue state here:
        // - Notification action callbacks and AppIntents run under tight compute-time
        //   limits and can be terminated before multi-step async work converges.
        // - Persisting a tiny confirmation marker keeps the callback deterministic,
        //   then AlarmStore performs the heavier wake-check teardown/scheduling work
        //   on the main app actor during normal reconciliation.
        let pendingWakeQueues = WakeUpCheckCoordinator.pendingWakeQueuesAfterConfirmAction(
            alarmID: alarmID,
            pendingStartIDs: AlarmPersistence.loadPendingWakeUpCheckStartIDs(),
            pendingConfirmIDs: AlarmPersistence.loadPendingWakeUpCheckConfirmIDs()
        )
        AlarmPersistence.savePendingWakeUpCheckStartIDs(pendingWakeQueues.pendingStartIDs)
        AlarmPersistence.savePendingWakeUpCheckConfirmIDs(pendingWakeQueues.pendingConfirmIDs)

        // Best effort immediate shutdown for already-armed wake-check alarms.
        try? AlarmManager.shared.stop(id: alarmID)
        try? AlarmManager.shared.cancel(id: alarmID)
    }
}
