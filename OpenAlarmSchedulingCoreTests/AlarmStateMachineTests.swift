import XCTest
@testable import OpenAlarmSchedulingCore

final class AlarmStateMachineTests: XCTestCase {

    private func makeAlarm(
        trigger: AlarmTrigger = .time(hour: 7, minute: 0),
        recurrence: AlarmRecurrence = .none,
        deleteAfterUse: Bool = true
    ) -> AlarmDefinition {
        AlarmDefinition(
            trigger: trigger,
            recurrence: recurrence,
            deleteAfterUse: deleteAfterUse
        )
    }

    private let defaultSettings = AlarmSettings.defaults

    // MARK: - Enable

    func testEnableFromIdleSchedulesAlarm() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .idle,
            event: .enabled,
            alarm: alarm,
            settings: defaultSettings
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
            settings: defaultSettings
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
            settings: defaultSettings
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
            settings: defaultSettings
        )

        XCTAssertEqual(result.phase, .alerting(alarmKitID: alarm.id))
        XCTAssertEqual(result.effects, [])
    }

    // MARK: - Stop (one-shot, deleteAfterUse)

    func testStopOneShotDeleteAfterUseCompletesAndDeletes() {
        let alarm = makeAlarm(deleteAfterUse: true)
        let result = AlarmStateMachine.transition(
            current: .alerting(alarmKitID: alarm.id),
            event: .stopped(alarmKitID: alarm.id),
            alarm: alarm,
            settings: defaultSettings
        )

        XCTAssertEqual(result.phase, .completed)
        XCTAssertTrue(result.effects.contains(.deleteAlarm(alarm.id)))
        XCTAssertTrue(result.effects.contains(.cancelAlarmKit(ids: [alarm.id])))
    }

    // MARK: - Stop (one-shot, keep after use)

    func testStopOneShotKeepAfterUseCompletesWithoutDelete() {
        let alarm = makeAlarm(deleteAfterUse: false)
        let result = AlarmStateMachine.transition(
            current: .alerting(alarmKitID: alarm.id),
            event: .stopped(alarmKitID: alarm.id),
            alarm: alarm,
            settings: defaultSettings
        )

        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: [alarm.id])])
        XCTAssertFalse(result.effects.contains(.deleteAlarm(alarm.id)))
    }

    // MARK: - Delete

    func testDeleteFromScheduledCancelsAndDeletes() {
        let alarm = makeAlarm()
        let result = AlarmStateMachine.transition(
            current: .scheduled(alarmKitIDs: [alarm.id]),
            event: .deleted,
            alarm: alarm,
            settings: defaultSettings
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
            settings: defaultSettings
        )

        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.effects, [.deleteAlarm(alarm.id)])
    }
}
