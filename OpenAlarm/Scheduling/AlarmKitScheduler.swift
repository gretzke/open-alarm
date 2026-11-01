import AlarmKit
import Foundation

@MainActor
final class AlarmKitScheduler: AlarmManagerScheduling {
    private let manager: AlarmManager

    init(manager: AlarmManager = .shared) {
        self.manager = manager
    }

    var alarms: [ScheduledAlarm] {
        get throws { try manager.alarms.map(Self.snapshot) }
    }

    func alarmUpdatesForStore() -> AsyncStream<[ScheduledAlarm]>? {
        let (stream, continuation) = AsyncStream.makeStream(of: [ScheduledAlarm].self)
        let manager = manager
        let task = Task {
            for await alarms in manager.alarmUpdates {
                guard !Task.isCancelled else { break }
                continuation.yield(alarms.map(Self.snapshot))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func schedule(id: UUID, configuration request: AlarmSchedulingRequest) async throws {
        let configuration: AlarmManager.AlarmConfiguration<OpenAlarmMetadata>
        switch request {
        case let .primary(alarm, schedule, settings, forceDisableSnooze, ringtoneID):
            configuration = AlarmConfigurationBuilder.makeConfiguration(
                for: alarm,
                schedule: schedule.alarmKitSchedule,
                defaultSharedSettings: settings,
                forceDisableSnooze: forceDisableSnooze,
                ringtoneID: ringtoneID
            )
        case let .bridge(alarm, bridgeID, schedule, settings, ringtoneID):
            configuration = AlarmConfigurationBuilder.makeBridgeConfiguration(
                for: alarm,
                bridgeID: bridgeID,
                schedule: schedule.alarmKitSchedule,
                defaultSharedSettings: settings,
                ringtoneID: ringtoneID
            )
        case let .wakeCheckBackup(alarm, deadlineAt, settings, ringtoneID):
            configuration = AlarmConfigurationBuilder.makeWakeCheckBackupConfiguration(
                for: alarm,
                deadlineAt: deadlineAt,
                resolvedSettings: settings,
                ringtoneID: ringtoneID
            )
        case let .forceClose(alarm, fireAt, settings, ringtoneID):
            configuration = AlarmConfigurationBuilder.makeForceCloseAlarmConfiguration(
                for: alarm,
                fireAt: fireAt,
                resolvedSettings: settings,
                ringtoneID: ringtoneID
            )
        }
        _ = try await manager.schedule(id: id, configuration: configuration)
    }

    func stop(id: UUID) throws {
        try manager.stop(id: id)
    }

    func cancel(id: UUID) throws {
        try manager.cancel(id: id)
    }

    private static func snapshot(_ alarm: Alarm) -> ScheduledAlarm {
        let state: ScheduledAlarm.State
        switch alarm.state {
        case .scheduled: state = .scheduled
        case .countdown: state = .countdown
        case .paused: state = .paused
        case .alerting: state = .alerting
        @unknown default: state = .unknown
        }
        return ScheduledAlarm(id: alarm.id, state: state)
    }
}

private extension AlarmSchedule {
    var alarmKitSchedule: Alarm.Schedule {
        switch self {
        case .fixed(let date):
            return .fixed(date)
        case let .relative(hour, minute, repeatDays):
            let time = Alarm.Schedule.Relative.Time(hour: hour, minute: minute)
            return .relative(.init(
                time: time,
                repeats: repeatDays.isEmpty ? .never : .weekly(repeatDays.map(\.localeWeekday))
            ))
        }
    }
}
