import Foundation
@testable import OpenAlarmSchedulingCore

struct CheckFailure: Error {
    let message: String
}

func expectEqual<T: Equatable>(
    _ lhs: T,
    _ rhs: T,
    _ message: String
) throws {
    guard lhs == rhs else {
        throw CheckFailure(message: "\(message)\nexpected: \(rhs)\nactual:   \(lhs)")
    }
}

func expectTrue(
    _ value: Bool,
    _ message: String
) throws {
    guard value else {
        throw CheckFailure(message: message)
    }
}

@main
struct AlarmSchedulingCoreChecks {
    static func main() {
        do {
            try runChecks()
            print("All scheduling core checks passed (4/4)")
        } catch {
            if let failure = error as? CheckFailure {
                fputs("FAIL: \(failure.message)\n", stderr)
            } else {
                fputs("FAIL: Unexpected error: \(error)\n", stderr)
            }
            exit(1)
        }
    }

    static func runChecks() throws {
        // 1) AlarmStateMachine: enable from idle schedules alarm
        do {
            let alarm = AlarmDefinition(trigger: .time(hour: 7, minute: 0))
            let settings = AlarmSettings.defaults
            let result = AlarmStateMachine.transition(
                current: .idle,
                event: .enabled,
                alarm: alarm,
                settings: settings
            )
            try expectEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]), "enable from idle should schedule")
            try expectEqual(result.effects, [
                .scheduleAlarmKit(alarmID: alarm.id, trigger: alarm.trigger, recurrence: alarm.recurrence)
            ], "enable should emit schedule effect")
        }

        // 2) AlarmStateMachine: delete from scheduled cancels and deletes
        do {
            let alarm = AlarmDefinition(trigger: .time(hour: 7, minute: 0))
            let settings = AlarmSettings.defaults
            let result = AlarmStateMachine.transition(
                current: .scheduled(alarmKitIDs: [alarm.id]),
                event: .deleted,
                alarm: alarm,
                settings: settings
            )
            try expectEqual(result.phase, .idle, "delete should transition to idle")
            try expectTrue(result.effects.contains(.cancelAlarmKit(ids: [alarm.id])), "delete should cancel")
            try expectTrue(result.effects.contains(.deleteAlarm(alarm.id)), "delete should remove alarm")
        }

        // 3) AlarmStateMachine: stop one-shot delete-after-use completes and deletes
        do {
            let alarm = AlarmDefinition(trigger: .time(hour: 7, minute: 0), deleteAfterUse: true)
            let settings = AlarmSettings.defaults
            let result = AlarmStateMachine.transition(
                current: .alerting(alarmKitID: alarm.id),
                event: .stopped(alarmKitID: alarm.id),
                alarm: alarm,
                settings: settings
            )
            try expectEqual(result.phase, .completed, "stop one-shot should complete")
            try expectTrue(result.effects.contains(.deleteAlarm(alarm.id)), "stop one-shot should delete")
        }

        // 4) AlarmStateMachine: disable from idle is no-op
        do {
            let alarm = AlarmDefinition(trigger: .time(hour: 7, minute: 0))
            let settings = AlarmSettings.defaults
            let result = AlarmStateMachine.transition(
                current: .idle,
                event: .disabled,
                alarm: alarm,
                settings: settings
            )
            try expectEqual(result.phase, .idle, "disable from idle stays idle")
            try expectTrue(result.effects.isEmpty, "disable from idle has no effects")
        }
    }
}
