import ActivityKit
import Foundation
import UIKit

extension AlarmStore {
    convenience init() {
        self.init(
            alarmManager: AlarmKitScheduler(),
            permissionService: AlarmPermissionService(),
            notificationPermissionService: NotificationPermissionService(),
            environment: .iOS,
            wakeCheckNotificationService: WakeUpCheckNotificationService()
        )
    }
}

extension AlarmStoreEnvironment {
    static var iOS: Self {
        Self(
            liveActivitiesEnabled: { ActivityAuthorizationInfo().areActivitiesEnabled },
            isInteractivelyVisible: {
                UIApplication.shared.isProtectedDataAvailable
                    && UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
            },
            syncNapActivity: { NapCountdownLiveActivityManager.shared.sync(with: $0) },
            stopNapActivity: { NapCountdownLiveActivityManager.shared.stop() },
            openSettings: {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            },
            protectedDataAvailableNotification: UIApplication.protectedDataDidBecomeAvailableNotification
        )
    }
}

extension ForceCloseAlarmManager {
    convenience init(
        alarm: AlarmDefinition,
        resolvedSettings: SharedAlarmSettings,
        defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults
    ) {
        self.init(
            alarm: alarm,
            resolvedSettings: resolvedSettings,
            alarmManager: AlarmKitScheduler(),
            defaults: defaults
        )
    }
}
