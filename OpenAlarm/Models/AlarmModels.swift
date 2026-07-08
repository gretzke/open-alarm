import AlarmKit
import Foundation
import UserNotifications

// AlarmKit/UserNotifications-dependent model layer. Foundation-only types live
// in AlarmSettingsCore.swift / AlarmDefinition.swift / AlarmPersistenceStore.swift
// so they can be compiled and tested in the OpenAlarmSchedulingCore SPM package.

// MARK: - OpenAlarmMetadata

struct OpenAlarmMetadata: AlarmMetadata {
    var source: String
    var isShadowTrial: Bool
    var createdAt: Date

    init(source: String, isShadowTrial: Bool) {
        self.source = source
        self.isShadowTrial = isShadowTrial
        self.createdAt = .now
    }
}

// MARK: - AlarmButton Extensions

extension AlarmButton {
    static var stopButton: Self {
        AlarmButton(
            text: LocalizedStringResource("alarm_button_done"),
            textColor: .white,
            systemImageName: "stop.circle"
        )
    }

    static var snoozeButton: Self {
        AlarmButton(
            text: LocalizedStringResource("alarm_button_snooze"),
            textColor: .black,
            systemImageName: "zzz"
        )
    }
}

// MARK: - AlarmDefinition + AlarmKit Schedule

extension AlarmDefinition {
    var schedule: Alarm.Schedule {
        let time = Alarm.Schedule.Relative.Time(hour: hour, minute: minute)
        if repeatDays.isEmpty {
            return .relative(.init(time: time, repeats: .never))
        }

        return .relative(.init(
            time: time,
            repeats: .weekly(sortedRepeatDays.map(\.localeWeekday))
        ))
    }
}

// MARK: - AlarmScheduleResolver

enum AlarmScheduleResolver {
    static func runtimeSchedule(for alarm: UserAlarm) -> Alarm.Schedule {
        switch alarm.type {
        case .nap, .tryOut:
            if let fixedDate = alarm.fixedTriggerDate {
                return .fixed(fixedDate)
            }
            return alarm.schedule
        case .regular:
            return alarm.schedule
        }
    }
}

// MARK: - WakeUpCheckConfirmationPresentation

struct WakeUpCheckConfirmationPresentation: Identifiable {
    let id: UUID
}

// MARK: - NotificationPermissionStatus

enum NotificationPermissionStatus: Equatable {
    case notDetermined
    case denied
    case authorized
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
final class WakeUpCheckNotificationService {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func scheduleWakeCheckNotification(
        alarmID: UUID,
        cycle: Int,
        triggerDate: Date
    ) async {
        let notificationID = WakeUpCheckNotificationConstants.notificationID(alarmID: alarmID, cycle: cycle)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "wake_check_notification_title")
        content.body = String(localized: "wake_check_notification_body")
        content.sound = .default
        content.categoryIdentifier = WakeUpCheckNotificationConstants.categoryID
        content.userInfo = [
            WakeUpCheckNotificationConstants.alarmIDUserInfoKey: alarmID.uuidString,
            WakeUpCheckNotificationConstants.cycleUserInfoKey: cycle,
        ]

        let delay = max(1, triggerDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: trigger)

        do {
            try await center.add(request)
        } catch {
            // Best-effort; if notification scheduling fails the backup alarm will still fire
        }
    }

    func cancelNotification(id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
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
}
