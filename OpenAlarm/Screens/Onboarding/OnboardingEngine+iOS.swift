import Foundation
import UIKit

extension OnboardingEngine {
    convenience init(
        userDefaults: UserDefaults = .standard,
        alarmPersistence: AlarmPersistence = .shared
    ) {
        let permissionService = AlarmPermissionService()
        self.init(
            userDefaults: userDefaults,
            alarmPersistence: alarmPersistence,
            alarmPermissionStatusProvider: { permissionService.currentStatus() },
            taskPermissionStatusProvider: TaskPermissionAuthorizer.status(for:),
            requestAlarmAuthorization: { await permissionService.requestAuthorization() },
            openSystemSettings: {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
        )
    }
}
