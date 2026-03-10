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
            print("All scheduling core checks passed (7/7)")
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
        let defaults = SharedAlarmSettings.featureDefaults
        let wakeCheckSettings = SharedAlarmSettings(
            snoozeEnabled: false,
            snoozeDurationMinutes: 5,
            maxSnoozes: 3,
            wakeUpCheckEnabled: true,
            wakeUpCheckDelayMinutes: 5,
            wakeUpCheckResponseTimeoutMinutes: 3
        )

        // 1) AlarmStateMachine: enable from idle schedules alarm
        do {
            let alarm = AlarmDefinition(trigger: .time(hour: 7, minute: 0))
            let result = AlarmStateMachine.transition(
                current: .idle,
                event: .enabled,
                alarm: alarm,
                resolvedSettings: defaults
            )
            try expectEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]), "enable from idle should schedule")
            try expectEqual(result.effects, [
                .scheduleAlarmKit(alarmID: alarm.id, trigger: alarm.trigger, recurrence: alarm.recurrence)
            ], "enable should emit schedule effect")
        }

        // 2) AlarmStateMachine: delete from scheduled cancels and deletes
        do {
            let alarm = AlarmDefinition(trigger: .time(hour: 7, minute: 0))
            let result = AlarmStateMachine.transition(
                current: .scheduled(alarmKitIDs: [alarm.id]),
                event: .deleted,
                alarm: alarm,
                resolvedSettings: defaults
            )
            try expectEqual(result.phase, .idle, "delete should transition to idle")
            try expectTrue(result.effects.contains(.cancelAlarmKit(ids: [alarm.id])), "delete should cancel")
            try expectTrue(result.effects.contains(.deleteAlarm(alarm.id)), "delete should remove alarm")
        }

        // 3) AlarmStateMachine: stop always transitions to awaitingDisarmChallenge
        do {
            let alarm = AlarmDefinition(trigger: .time(hour: 7, minute: 0), deleteAfterUse: true)
            let result = AlarmStateMachine.transition(
                current: .alerting(alarmKitID: alarm.id),
                event: .stopped(alarmKitID: alarm.id),
                alarm: alarm,
                resolvedSettings: defaults
            )
            try expectEqual(result.phase, .awaitingDisarmChallenge(alarmKitID: alarm.id), "stop should transition to awaitingDisarmChallenge")
            try expectTrue(result.effects.isEmpty, "stop to awaitingDisarmChallenge should have no effects")
        }

        // 4) AlarmStateMachine: disable from idle is no-op
        do {
            let alarm = AlarmDefinition(trigger: .time(hour: 7, minute: 0))
            let result = AlarmStateMachine.transition(
                current: .idle,
                event: .disabled,
                alarm: alarm,
                resolvedSettings: defaults
            )
            try expectEqual(result.phase, .idle, "disable from idle stays idle")
            try expectTrue(result.effects.isEmpty, "disable from idle has no effects")
        }

        // 5) AlarmStateMachine: snooze from alerting transitions to snoozed
        do {
            let alarm = AlarmDefinition(trigger: .time(hour: 7, minute: 0))
            let result = AlarmStateMachine.transition(
                current: .alerting(alarmKitID: alarm.id),
                event: .snoozed(alarmKitID: alarm.id),
                alarm: alarm,
                resolvedSettings: defaults
            )
            try expectEqual(result.phase, .snoozed(alarmKitID: alarm.id), "snooze should transition to snoozed")
        }

        // 6) AlarmStateMachine: stop with wake-check transitions to awaitingDisarmChallenge
        do {
            let alarm = AlarmDefinition(trigger: .time(hour: 7, minute: 0))
            let result = AlarmStateMachine.transition(
                current: .alerting(alarmKitID: alarm.id),
                event: .stopped(alarmKitID: alarm.id),
                alarm: alarm,
                resolvedSettings: wakeCheckSettings
            )
            try expectEqual(result.phase, .awaitingDisarmChallenge(alarmKitID: alarm.id), "stop should always transition to awaitingDisarmChallenge")
            try expectTrue(result.effects.isEmpty, "stop to awaitingDisarmChallenge should have no effects")
        }

        // 7) AlarmStateMachine: wake-check confirmed repeating reschedules
        do {
            let alarm = AlarmDefinition(
                trigger: .time(hour: 7, minute: 0),
                recurrence: .weekly([.monday, .friday])
            )
            let result = AlarmStateMachine.transition(
                current: .awaitingWakeCheck,
                event: .wakeCheckConfirmed,
                alarm: alarm,
                resolvedSettings: wakeCheckSettings
            )
            try expectEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]), "wake-check confirmed repeating should reschedule")
            try expectEqual(result.effects, [
                .scheduleAlarmKit(alarmID: alarm.id, trigger: alarm.trigger, recurrence: alarm.recurrence)
            ], "should emit schedule effect")
        }
    }
}
