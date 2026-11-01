import Foundation

/// The runtime state needed by the app, independent of AlarmKit's value types.
struct ScheduledAlarm: Sendable {
    enum State: Equatable, Sendable {
        case scheduled
        case countdown
        case paused
        case alerting
        case unknown
    }

    let id: UUID
    let state: State
}

enum AlarmSchedule: Equatable, Sendable {
    case fixed(Date)
    case relative(hour: Int, minute: Int, repeatDays: [AlarmWeekday])

    static func runtimeSchedule(for alarm: AlarmDefinition) -> Self {
        if (alarm.isNap || alarm.isTryOut), let fixedDate = alarm.fixedTriggerDate {
            return .fixed(fixedDate)
        }
        return .relative(hour: alarm.hour, minute: alarm.minute, repeatDays: alarm.sortedRepeatDays)
    }
}

/// A request is converted to the real AlarmKit configuration by AlarmKitScheduler.
enum AlarmSchedulingRequest: Sendable {
    case primary(AlarmDefinition, AlarmSchedule, SharedAlarmSettings, forceDisableSnooze: Bool, ringtoneID: String?)
    case bridge(AlarmDefinition, bridgeID: UUID, AlarmSchedule, SharedAlarmSettings, ringtoneID: String?)
    case wakeCheckBackup(AlarmDefinition, deadlineAt: Date, SharedAlarmSettings, ringtoneID: String?)
    case forceClose(AlarmDefinition, fireAt: Date, SharedAlarmSettings, ringtoneID: String?)

    static func makeConfiguration(
        for alarm: AlarmDefinition,
        schedule: AlarmSchedule,
        defaultSharedSettings: SharedAlarmSettings,
        forceDisableSnooze: Bool = false,
        ringtoneID: String? = nil
    ) -> Self {
        .primary(alarm, schedule, defaultSharedSettings, forceDisableSnooze: forceDisableSnooze, ringtoneID: ringtoneID)
    }

    static func makeBridgeConfiguration(
        for alarm: AlarmDefinition,
        bridgeID: UUID,
        schedule: AlarmSchedule,
        defaultSharedSettings: SharedAlarmSettings,
        ringtoneID: String? = nil
    ) -> Self {
        .bridge(alarm, bridgeID: bridgeID, schedule, defaultSharedSettings, ringtoneID: ringtoneID)
    }

    static func makeWakeCheckBackupConfiguration(
        for alarm: AlarmDefinition,
        deadlineAt: Date,
        resolvedSettings: SharedAlarmSettings,
        ringtoneID: String? = nil
    ) -> Self {
        .wakeCheckBackup(alarm, deadlineAt: deadlineAt, resolvedSettings, ringtoneID: ringtoneID)
    }

    static func makeForceCloseAlarmConfiguration(
        for alarm: AlarmDefinition,
        fireAt: Date,
        resolvedSettings: SharedAlarmSettings,
        ringtoneID: String? = nil
    ) -> Self {
        .forceClose(alarm, fireAt: fireAt, resolvedSettings, ringtoneID: ringtoneID)
    }
}

@MainActor
protocol AlarmManagerScheduling: AnyObject {
    var alarms: [ScheduledAlarm] { get throws }
    func alarmUpdatesForStore() -> AsyncStream<[ScheduledAlarm]>?
    func schedule(id: UUID, configuration: AlarmSchedulingRequest) async throws
    func stop(id: UUID) throws
    func cancel(id: UUID) throws
}
