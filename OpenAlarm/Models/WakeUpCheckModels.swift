import Foundation

// MARK: - WakeUpCheckConfirmationPresentation

struct WakeUpCheckConfirmationPresentation: Identifiable {
    let id: UUID
}

// MARK: - WakeUpCheckNotificationConstants

enum WakeUpCheckNotificationConstants {
    static let categoryID = "OPENALARM_WAKE_CHECK"
    static let alarmIDUserInfoKey = "alarmID"
    static let cycleUserInfoKey = "cycle"

    static func notificationID(alarmID: UUID, cycle: Int) -> String {
        "wakecheck.\(alarmID.uuidString).\(cycle)"
    }
}

// MARK: - WakeUpCheckAction

enum WakeUpCheckAction: String {
    case confirmAwake = "WAKE_CHECK_CONFIRM_AWAKE"
}

// MARK: - Notification.Name

extension Notification.Name {
    static let wakeUpCheckConfirmationRequested = Notification.Name("wakeUpCheckConfirmationRequested")
    static let disarmChallengeRequested = Notification.Name("disarmChallengeRequested")
}

// MARK: - WakeUpCheckNotificationService

@MainActor
protocol WakeUpCheckNotificationServicing: AnyObject {
    func scheduleWakeCheckNotification(
        alarmID: UUID,
        cycle: Int,
        triggerDate: Date,
        shouldSchedule: @escaping @MainActor () -> Bool
    ) async
    func cancelNotification(id: String)
    func ensureCategoryRegistered()
}

