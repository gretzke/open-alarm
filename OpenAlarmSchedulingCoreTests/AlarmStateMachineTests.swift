import XCTest
@testable import OpenAlarmSchedulingCore

final class AlarmStateMachineTests: XCTestCase {

    private func makeAlarm(
        hour: Int = 7,
        minute: Int = 0,
        repeatDays: [AlarmWeekday] = [],
        deleteAfterUse: Bool = true,
        type: AlarmType = .regular
    ) -> AlarmDefinition {
        let recurrence: AlarmRecurrence = repeatDays.isEmpty ? .none : .weekly(repeatDays)
        return AlarmDefinition(
            trigger: .time(hour: hour, minute: minute),
            recurrence: recurrence,
            type: type,
            deleteAfterUse: deleteAfterUse
        )
    }

    private let defaultSettings = SharedAlarmSettings.featureDefaults

    private var wakeCheckSettings: SharedAlarmSettings {
        SharedAlarmSettings(
            snoozeEnabled: false,
            snoozeDurationMinutes: 5,
            maxSnoozes: 3,
            wakeUpCheckEnabled: true,
            wakeUpCheckDelayMinutes: 5,
            wakeUpCheckResponseTimeoutMinutes: 3
        )
    }

    // MARK: - Enable

    func testEnableFromIdleSchedulesAlarm() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .idle,
            event: .enabled,
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]))
        XCTAssertEqual(result.effects, [
            .scheduleAlarmKit(alarmID: alarm.id, trigger: alarm.trigger, recurrence: alarm.recurrence)
        ])
    }

    // MARK: - Disable

    func testDisableFromScheduledCancelsAlarm() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .scheduled(alarmKitIDs: [alarm.id]),
            event: .disabled,
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: [alarm.id])])
    }

    func testDisableFromIdleIsNoOp() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .idle,
            event: .disabled,
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.effects, [])
    }

    // MARK: - Alerting transition

    func testAlarmKitAlertingTransitionsToAlerting() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .scheduled(alarmKitIDs: [alarm.id]),
            event: .alarmKitStateChanged(alarmKitID: alarm.id, newState: .alerting),
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .alerting(alarmKitID: alarm.id))
        XCTAssertEqual(result.effects, [])
    }

    // MARK: - Stop (always transitions to awaitingDisarmChallenge)

    func testStopOneShotDeleteAfterUseCompletesAndDeletes() {
        let alarm = makeAlarm(deleteAfterUse: true)
        let result = AlarmStateMachine.transition(
            current: .alerting(alarmKitID: alarm.id),
            event: .stopped(alarmKitID: alarm.id),
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .awaitingDisarmChallenge(alarmKitID: alarm.id))
        XCTAssertEqual(result.effects, [])
    }

    func testStopOneShotKeepAfterUseCompletesWithoutDelete() {
        let alarm = makeAlarm(deleteAfterUse: false)
        let result = AlarmStateMachine.transition(
            current: .alerting(alarmKitID: alarm.id),
            event: .stopped(alarmKitID: alarm.id),
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .awaitingDisarmChallenge(alarmKitID: alarm.id))
        XCTAssertEqual(result.effects, [])
    }

    func testStopAlwaysTransitionsToAwaitingDisarmChallenge() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .alerting(alarmKitID: alarm.id),
            event: .stopped(alarmKitID: alarm.id),
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .awaitingDisarmChallenge(alarmKitID: alarm.id))
        XCTAssertEqual(result.effects, [])
    }

    // MARK: - Delete

    func testDeleteFromScheduledCancelsAndDeletes() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .scheduled(alarmKitIDs: [alarm.id]),
            event: .deleted,
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .idle)
        XCTAssertTrue(result.effects.contains(.cancelAlarmKit(ids: [alarm.id])))
        XCTAssertTrue(result.effects.contains(.deleteAlarm(alarm.id)))
    }

    func testDeleteFromIdleJustDeletes() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .idle,
            event: .deleted,
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.effects, [.deleteAlarm(alarm.id)])
    }

    // MARK: - Snooze

    func testSnoozeFromAlertingTransitionsToSnoozed() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .alerting(alarmKitID: alarm.id),
            event: .snoozed(alarmKitID: alarm.id),
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .snoozed(alarmKitID: alarm.id))
        XCTAssertEqual(result.effects, [
            .scheduleAlarmKit(alarmID: alarm.id, trigger: alarm.trigger, recurrence: alarm.recurrence)
        ])
    }

    func testSnoozedAlertingTransitionsBackToAlerting() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .snoozed(alarmKitID: alarm.id),
            event: .alarmKitStateChanged(alarmKitID: alarm.id, newState: .alerting),
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .alerting(alarmKitID: alarm.id))
        XCTAssertEqual(result.effects, [])
    }

    // MARK: - Stop with wake-check

    func testStopWithWakeCheckTransitionsToAwaitingDisarmChallenge() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .alerting(alarmKitID: alarm.id),
            event: .stopped(alarmKitID: alarm.id),
            alarm: alarm,
            resolvedSettings: wakeCheckSettings
        )

        XCTAssertEqual(result.phase, .awaitingDisarmChallenge(alarmKitID: alarm.id))
        XCTAssertEqual(result.effects, [])
    }

    func testStopFromAwaitingWakeCheckStaysInWakeCheck() {
        let alarm = makeAlarm()
        let backupID = alarm.id
        let result = AlarmStateMachine.transition(
            current: .awaitingWakeCheck,
            event: .stopped(alarmKitID: backupID),
            alarm: alarm,
            resolvedSettings: wakeCheckSettings
        )

        XCTAssertEqual(result.phase, .awaitingWakeCheck)
        XCTAssertEqual(result.effects, [])
    }

    // MARK: - Wake-check confirmed

    func testWakeCheckConfirmedRepeatingReschedulesAlarm() {
        let alarm = makeAlarm(repeatDays: [.monday, .friday])
        let result = AlarmStateMachine.transition(
            current: .awaitingWakeCheck,
            event: .wakeCheckConfirmed,
            alarm: alarm,
            resolvedSettings: wakeCheckSettings
        )

        XCTAssertEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]))
        XCTAssertEqual(result.effects, [
            .scheduleAlarmKit(alarmID: alarm.id, trigger: alarm.trigger, recurrence: alarm.recurrence)
        ])
    }

    func testWakeCheckConfirmedOneShotDeleteAfterUseDeletes() {
        let alarm = makeAlarm(deleteAfterUse: true)
        let result = AlarmStateMachine.transition(
            current: .awaitingWakeCheck,
            event: .wakeCheckConfirmed,
            alarm: alarm,
            resolvedSettings: wakeCheckSettings
        )

        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.effects, [.deleteAlarm(alarm.id)])
    }

    func testWakeCheckConfirmedOneShotKeepAfterUseCompletes() {
        let alarm = makeAlarm(deleteAfterUse: false)
        let result = AlarmStateMachine.transition(
            current: .awaitingWakeCheck,
            event: .wakeCheckConfirmed,
            alarm: alarm,
            resolvedSettings: wakeCheckSettings
        )

        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.effects, [])
    }

    func testWakeCheckConfirmedNapDeletes() {
        let alarm = makeAlarm(type: .nap(NapConfig(durationMinutes: 30, pausedRemainingSeconds: nil)))
        let result = AlarmStateMachine.transition(
            current: .awaitingWakeCheck,
            event: .wakeCheckConfirmed,
            alarm: alarm,
            resolvedSettings: wakeCheckSettings
        )

        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.effects, [.deleteAlarm(alarm.id)])
    }

    // MARK: - Updated

    func testUpdatedReschedulesEnabledAlarm() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .scheduled(alarmKitIDs: [alarm.id]),
            event: .updated,
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]))
        XCTAssertTrue(result.effects.contains(.cancelAlarmKit(ids: [alarm.id])))
        XCTAssertTrue(result.effects.contains(
            .scheduleAlarmKit(alarmID: alarm.id, trigger: alarm.trigger, recurrence: alarm.recurrence)
        ))
    }

    func testUpdatedDisabledAlarmGoesToIdle() {
        var alarm = makeAlarm()
        alarm.isEnabled = false
        let result = AlarmStateMachine.transition(
            current: .scheduled(alarmKitIDs: [alarm.id]),
            event: .updated,
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: [alarm.id])])
    }

    // MARK: - Delete from snoozed

    func testDeleteFromSnoozedCancelsAndDeletes() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .snoozed(alarmKitID: alarm.id),
            event: .deleted,
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .idle)
        XCTAssertTrue(result.effects.contains(.cancelAlarmKit(ids: [alarm.id])))
        XCTAssertTrue(result.effects.contains(.deleteAlarm(alarm.id)))
    }

    // MARK: - Delete from awaitingWakeCheck

    func testDeleteFromAwaitingWakeCheckDeletes() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .awaitingWakeCheck,
            event: .deleted,
            alarm: alarm,
            resolvedSettings: wakeCheckSettings
        )

        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.effects, [.deleteAlarm(alarm.id)])
    }

    // MARK: - Stop repeating alarm (no wake-check)

    func testStopRepeatingAlarmReschedules() {
        let alarm = makeAlarm(repeatDays: [.monday, .wednesday, .friday])
        let result = AlarmStateMachine.transition(
            current: .alerting(alarmKitID: alarm.id),
            event: .stopped(alarmKitID: alarm.id),
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .awaitingDisarmChallenge(alarmKitID: alarm.id))
        XCTAssertEqual(result.effects, [])
    }

    // MARK: - Challenge completed

    func testChallengeCompletedWithWakeCheckTransitionsToAwaitingWakeCheck() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .awaitingDisarmChallenge(alarmKitID: alarm.id),
            event: .challengeCompleted(alarmKitID: alarm.id),
            alarm: alarm,
            resolvedSettings: wakeCheckSettings
        )

        XCTAssertEqual(result.phase, .awaitingWakeCheck)
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: [alarm.id])])
    }

    func testChallengeCompletedRepeatingReschedules() {
        let alarm = makeAlarm(repeatDays: [.monday, .wednesday, .friday])
        let result = AlarmStateMachine.transition(
            current: .awaitingDisarmChallenge(alarmKitID: alarm.id),
            event: .challengeCompleted(alarmKitID: alarm.id),
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]))
        XCTAssertEqual(result.effects, [
            .scheduleAlarmKit(alarmID: alarm.id, trigger: alarm.trigger, recurrence: alarm.recurrence)
        ])
    }

    func testChallengeCompletedOneShotDeleteAfterUseDeletes() {
        let alarm = makeAlarm(deleteAfterUse: true)
        let result = AlarmStateMachine.transition(
            current: .awaitingDisarmChallenge(alarmKitID: alarm.id),
            event: .challengeCompleted(alarmKitID: alarm.id),
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .completed)
        XCTAssertTrue(result.effects.contains(.cancelAlarmKit(ids: [alarm.id])))
        XCTAssertTrue(result.effects.contains(.deleteAlarm(alarm.id)))
    }

    func testChallengeCompletedOneShotKeepCompletes() {
        let alarm = makeAlarm(deleteAfterUse: false)
        let result = AlarmStateMachine.transition(
            current: .awaitingDisarmChallenge(alarmKitID: alarm.id),
            event: .challengeCompleted(alarmKitID: alarm.id),
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: [alarm.id])])
        XCTAssertFalse(result.effects.contains(.deleteAlarm(alarm.id)))
    }

    // MARK: - Awaiting disarm challenge edge cases

    func testStopFromAwaitingDisarmChallengeStays() {
        let alarm = makeAlarm()
        let otherID = UUID()
        let result = AlarmStateMachine.transition(
            current: .awaitingDisarmChallenge(alarmKitID: alarm.id),
            event: .stopped(alarmKitID: otherID),
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .awaitingDisarmChallenge(alarmKitID: alarm.id))
        XCTAssertEqual(result.effects, [])
    }

    func testDeleteFromAwaitingDisarmChallengeCancelsAndDeletes() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .awaitingDisarmChallenge(alarmKitID: alarm.id),
            event: .deleted,
            alarm: alarm,
            resolvedSettings: defaultSettings
        )

        XCTAssertEqual(result.phase, .idle)
        XCTAssertTrue(result.effects.contains(.cancelAlarmKit(ids: [alarm.id])))
        XCTAssertTrue(result.effects.contains(.deleteAlarm(alarm.id)))
    }
}
