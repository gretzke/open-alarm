import AlarmKit
import AppIntents
import Foundation
import UserNotifications

struct StopIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop"
    static var description = IntentDescription("Stop an alarm")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "alarmID")
    var alarmID: String

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    init() {
        self.alarmID = ""
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else {
            return .result()
        }

        let persistence = AlarmPersistence(defaults: .standard)
        let defaultSharedSettings = persistence.loadDefaultSharedSettings()
        var alarms = persistence.loadUserAlarms()

        guard let index = alarms.firstIndex(where: { $0.id == id }) else {
            try? AlarmManager.shared.stop(id: id)
            return .result()
        }

        var alarm = alarms[index]
        let effectiveDefaults: SharedAlarmSettings = alarm.isNap
            ? (persistence.loadNapDefaultSharedSettings() ?? defaultSharedSettings)
            : defaultSharedSettings
        let settings = alarm.resolvedSharedSettings(defaults: effectiveDefaults)

        if settings.wakeUpCheckEnabled {
            // Mark alarm as awaiting wake-check BEFORE stopping,
            // so applyRemoteAlarms doesn't clean it up during the async gap
            alarm.lifecycleState = .awaitingWakeCheck
            alarm.snoozeCount = 0
            alarm.updatedAt = .now
            alarms[index] = alarm
            persistence.saveUserAlarms(alarms)

            // Now stop and cancel the alerting alarm
            try? AlarmManager.shared.stop(id: id)
            try? AlarmManager.shared.cancel(id: id)

            // Create/advance wake-check session
            var sessions = persistence.loadWakeCheckSessions()
            let previousSession = sessions[id]
            let existingCycle = previousSession?.cycle ?? 0
            let newCycle = existingCycle + 1

            // Cancel previous cycle's notification
            if let previousNotificationID = previousSession?.notificationID {
                let notifCenter = UNUserNotificationCenter.current()
                notifCenter.removeDeliveredNotifications(withIdentifiers: [previousNotificationID])
                notifCenter.removePendingNotificationRequests(withIdentifiers: [previousNotificationID])
            }

            // Clear grace period flag
            var graceApplied = Self.loadGraceAppliedIDs()
            graceApplied.remove(id)
            Self.saveGraceAppliedIDs(graceApplied)

            // Clear pending confirm UI ID from previous cycle
            var pendingConfirmUIIDs = persistence.loadPendingWakeUpCheckShowConfirmUIIDs()
            pendingConfirmUIIDs.remove(id)
            persistence.savePendingWakeUpCheckShowConfirmUIIDs(pendingConfirmUIIDs)

            let checkDelay = WakeUpCheckTimingPolicy.checkDelayInterval(for: settings.wakeUpCheckDelayMinutes)
            let responseTimeout = WakeUpCheckTimingPolicy.responseTimeoutInterval(for: settings.wakeUpCheckResponseTimeoutMinutes)
            let checkAt = Date.now.addingTimeInterval(checkDelay)
            let deadlineAt = checkAt.addingTimeInterval(responseTimeout)
            let notificationID = WakeUpCheckNotificationConstants.notificationID(alarmID: id, cycle: newCycle)

            let session = WakeCheckSession(
                alarmID: id,
                cycle: newCycle,
                checkAt: checkAt,
                deadlineAt: deadlineAt,
                notificationID: notificationID
            )
            sessions[id] = session
            persistence.saveWakeCheckSessions(sessions)

            // Schedule notification
            let notifCenter = UNUserNotificationCenter.current()
            let notifSettings = await notifCenter.notificationSettings()
            if notifSettings.authorizationStatus == .authorized {
                let content = UNMutableNotificationContent()
                content.title = String(localized: "wake_check_notification_title")
                content.body = String(localized: "wake_check_notification_body")
                content.sound = .default
                content.categoryIdentifier = WakeUpCheckNotificationConstants.categoryID
                content.userInfo = [
                    WakeUpCheckNotificationConstants.alarmIDUserInfoKey: id.uuidString,
                    WakeUpCheckNotificationConstants.cycleUserInfoKey: newCycle,
                ]

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, checkDelay), repeats: false)
                let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: trigger)
                try? await notifCenter.add(request)
            }

            // Schedule backup alarm at deadline
            let config = AlarmConfigurationBuilder.makeWakeCheckBackupConfiguration(for: alarm, deadlineAt: deadlineAt)
            _ = try? await AlarmManager.shared.schedule(id: id, configuration: config)

        } else {
            // Normal stop path
            try? AlarmManager.shared.stop(id: id)

            alarm.snoozeCount = 0
            alarm.updatedAt = .now

            if alarm.isNap || alarm.isTryOut || (alarm.deleteAfterUse && !alarm.isRepeating) {
                alarms.remove(at: index)
            } else if alarm.isRepeating {
                alarm.lifecycleState = .scheduled
                alarms[index] = alarm
            } else {
                alarm.isEnabled = false
                alarm.lifecycleState = .completed
                alarms[index] = alarm
            }

            persistence.saveUserAlarms(alarms)
        }

        return .result()
    }

    // MARK: - Grace period helpers (shared key with AlarmStore)

    private static let graceAppliedKey = "OPENALARM_WAKE_CHECK_GRACE_APPLIED_IDS"

    static func loadGraceAppliedIDs() -> Set<UUID> {
        guard let raw = UserDefaults.standard.array(forKey: graceAppliedKey) as? [String] else {
            return []
        }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    static func saveGraceAppliedIDs(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: graceAppliedKey)
    }
}
