import Foundation

enum NotificationPermissionStatus: Equatable {
    case notDetermined
    case denied
    case authorized
}

struct WakeUpCheckDefaults: Codable, Equatable, Sendable {
    var enabledByDefault: Bool
    var delayMinutes: Int

    static let featureDefaults = WakeUpCheckDefaults(
        enabledByDefault: false,
        delayMinutes: 5
    )

    var clampedDelayMinutes: Int {
        min(60, max(1, delayMinutes))
    }
}

// Wake-check session state and coordinator live in AlarmScheduleReconciler.swift.

enum WakeUpCheckAction: String {
    case confirmAwake = "WAKE_CHECK_CONFIRM_AWAKE"
}

enum WakeUpCheckNotificationConstants {
    static let categoryID = "OPENALARM_WAKE_CHECK"
    static let alarmIDUserInfoKey = "alarmID"
    static let cycleUserInfoKey = "cycle"

    static func notificationID(alarmID: UUID, cycle: Int) -> String {
        "wakecheck.\(alarmID.uuidString).\(cycle)"
    }
}
