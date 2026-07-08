import XCTest
@testable import OpenAlarmSchedulingCore

final class AlarmStateMachineTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func makeAlarm(
        hour: Int = 7,
        minute: Int = 0,
        repeatDays: [AlarmWeekday] = [],
        deleteAfterUse: Bool = true,
        type: AlarmType = .regular,
        snoozeCount: Int = 0
    ) -> AlarmDefinition {
        let recurrence: AlarmRecurrence = repeatDays.isEmpty ? .none : .weekly(repeatDays)
        return AlarmDefinition(
            trigger: .time(hour: hour, minute: minute),
            recurrence: recurrence,
            type: type,
            deleteAfterUse: deleteAfterUse,
            snoozeCount: snoozeCount
        )
    }

    private func makeOverrideAlarm(
        bridgeAlarmIDs: [UUID],
        repeatDays: [AlarmWeekday] = [.monday, .wednesday, .friday]
    ) -> AlarmDefinition {
        var alarm = makeAlarm(repeatDays: repeatDays, deleteAfterUse: false)
        alarm.activeOverride = OverrideState(
            kind: .modifyNext,
            bridgeAlarmIDs: bridgeAlarmIDs,
            restoreAnchorDate: .now
        )
        return alarm
    }

    /// Expected `.persist` payload: lifecycle bookkeeping the machine applies.
    private func bookkept(
        _ alarm: AlarmDefinition,
        isEnabled: Bool? = nil,
        lifecycleState: AlarmLifecycleState
    ) -> AlarmDefinition {
        var updated = alarm
        updated.snoozeCount = 0
        if let isEnabled { updated.isEnabled = isEnabled }
        updated.lifecycleState = lifecycleState
        updated.updatedAt = now
        return updated
    }

    private func transition(
        _ current: AlarmSchedulingPhase,
        _ event: AlarmEvent,
        alarm: AlarmDefinition,
        settings: SharedAlarmSettings = .featureDefaults
    ) -> AlarmStateMachine.TransitionResult {
        AlarmStateMachine.transition(
            current: current,
            event: event,
            alarm: alarm,
            resolvedSettings: settings,
            now: now
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
        let result = transition(.idle, .enabled, alarm: alarm)

        XCTAssertEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]))
        XCTAssertEqual(result.effects, [.scheduleAlarmKit(alarmID: alarm.id)])
    }

    func testEnableFromCompletedSchedules() {
        // D-13: re-enabling a finished kept one-shot must schedule again.
        let alarm = makeAlarm(deleteAfterUse: false)
        let result = transition(.completed, .enabled, alarm: alarm)

        XCTAssertEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]))
        XCTAssertEqual(result.effects, [.scheduleAlarmKit(alarmID: alarm.id)])
    }

    func testEnableWhileScheduledIsNoOp() {
        let alarm = makeAlarm()
        let result = transition(.scheduled(alarmKitIDs: [alarm.id]), .enabled, alarm: alarm)

        XCTAssertEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]))
        XCTAssertEqual(result.effects, [])
    }

    // MARK: - Disable

    func testDisableFromScheduledCancelsAlarm() {
        let alarm = makeAlarm()
        let result = transition(.scheduled(alarmKitIDs: [alarm.id]), .disabled, alarm: alarm)

        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: [alarm.id])])
    }

    func testDisableFromIdleIsNoOp() {
        let alarm = makeAlarm()
        let result = transition(.idle, .disabled, alarm: alarm)

        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.effects, [])
    }

    func testDisableFromOverrideActiveCancelsBridges() {
        let alarm = makeAlarm(repeatDays: [.monday, .wednesday, .friday])
        let bridgeIDs: Set<UUID> = [UUID(), UUID(), UUID()]

        let result = transition(.overrideActive(bridgeAlarmIDs: bridgeIDs), .disabled, alarm: alarm)

        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: bridgeIDs)])
    }

    // MARK: - Delete

    func testDeleteFromScheduledCancelsAndDeletes() {
        let alarm = makeAlarm()
        let result = transition(.scheduled(alarmKitIDs: [alarm.id]), .deleted, alarm: alarm)

        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: [alarm.id]), .deleteAlarm(alarm.id)])
    }

    func testDeleteFromIdleJustDeletes() {
        let alarm = makeAlarm()
        let result = transition(.idle, .deleted, alarm: alarm)

        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.effects, [.deleteAlarm(alarm.id)])
    }

    func testDeleteFromSnoozedCancelsAndDeletes() {
        let alarm = makeAlarm()
        let result = transition(.snoozed(alarmKitID: alarm.id), .deleted, alarm: alarm)

        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: [alarm.id]), .deleteAlarm(alarm.id)])
    }

    func testDeleteFromAwaitingWakeCheckDeletes() {
        let alarm = makeAlarm()
        let result = transition(.awaitingWakeCheck, .deleted, alarm: alarm, settings: wakeCheckSettings)

        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.effects, [.deleteAlarm(alarm.id)])
    }

    func testDeleteFromAwaitingDisarmChallengeCancelsAndDeletes() {
        let alarm = makeAlarm()
        let result = transition(.awaitingDisarmChallenge(alarmKitID: alarm.id), .deleted, alarm: alarm)

        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: [alarm.id]), .deleteAlarm(alarm.id)])
    }

    func testDeleteFromOverrideActiveCancelsBridgesAndDeletes() {
        let alarm = makeAlarm(repeatDays: [.monday, .wednesday, .friday])
        let bridgeIDs: Set<UUID> = [UUID(), UUID(), UUID()]

        let result = transition(.overrideActive(bridgeAlarmIDs: bridgeIDs), .deleted, alarm: alarm)

        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: bridgeIDs), .deleteAlarm(alarm.id)])
    }

    // MARK: - Updated

    func testUpdatedReschedulesEnabledAlarm() {
        let alarm = makeAlarm()
        let result = transition(.scheduled(alarmKitIDs: [alarm.id]), .updated, alarm: alarm)

        XCTAssertEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]))
        XCTAssertEqual(result.effects, [
            .cancelAlarmKit(ids: [alarm.id]),
            .scheduleAlarmKit(alarmID: alarm.id),
        ])
    }

    func testUpdatedDisabledAlarmGoesToIdle() {
        var alarm = makeAlarm()
        alarm.isEnabled = false
        let result = transition(.scheduled(alarmKitIDs: [alarm.id]), .updated, alarm: alarm)

        XCTAssertEqual(result.phase, .idle)
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: [alarm.id])])
    }

    func testUpdatedFromOverrideActiveCancelsBridgesAndReschedules() {
        let alarm = makeAlarm(repeatDays: [.monday, .wednesday, .friday])
        let bridgeIDs: Set<UUID> = [UUID(), UUID(), UUID()]

        let result = transition(.overrideActive(bridgeAlarmIDs: bridgeIDs), .updated, alarm: alarm)

        XCTAssertEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]))
        XCTAssertEqual(result.effects, [
            .cancelAlarmKit(ids: bridgeIDs),
            .scheduleAlarmKit(alarmID: alarm.id),
        ])
    }

    // MARK: - Disarm requested (R-4.2)

    func testDisarmRequestedFromAnyPhaseEntersChallenge() {
        let alarm = makeAlarm()
        let firedID = UUID()
        let phases: [AlarmSchedulingPhase] = [
            .idle,
            .scheduled(alarmKitIDs: [alarm.id]),
            .overrideActive(bridgeAlarmIDs: [firedID, UUID()]),
            .awaitingWakeCheck,
            .alerting(alarmKitID: firedID),
            .snoozed(alarmKitID: firedID),
        ]

        for phase in phases {
            let result = transition(phase, .disarmRequested(alarmKitID: firedID), alarm: alarm)
            XCTAssertEqual(result.phase, .awaitingDisarmChallenge(alarmKitID: firedID), "from \(phase)")
            XCTAssertEqual(result.effects, [], "from \(phase)")
        }
    }

    // MARK: - Challenge completed (R-4.3 branch priority)

    func testChallengeCompletedWithWakeCheckTransitionsToAwaitingWakeCheck() {
        let alarm = makeAlarm(snoozeCount: 2)
        let result = transition(
            .awaitingDisarmChallenge(alarmKitID: alarm.id),
            .challengeCompleted(alarmKitID: alarm.id),
            alarm: alarm,
            settings: wakeCheckSettings
        )

        XCTAssertEqual(result.phase, .awaitingWakeCheck)
        XCTAssertEqual(result.effects, [
            .cancelAlarmKit(ids: [alarm.id]),
            .persist(bookkept(alarm, lifecycleState: .awaitingWakeCheck)),
        ])
    }

    func testChallengeCompletedWakeCheckWinsOverOverride() {
        // Branch priority: wake-check is checked before the override branch.
        let bridgeID = UUID()
        let alarm = makeOverrideAlarm(bridgeAlarmIDs: [bridgeID, UUID()])

        let result = transition(
            .awaitingDisarmChallenge(alarmKitID: bridgeID),
            .challengeCompleted(alarmKitID: bridgeID),
            alarm: alarm,
            settings: wakeCheckSettings
        )

        XCTAssertEqual(result.phase, .awaitingWakeCheck)
    }

    func testChallengeCompletedRepeatingEmitsPersistThenSchedule() {
        let alarm = makeAlarm(repeatDays: [.monday, .wednesday, .friday], deleteAfterUse: false, snoozeCount: 2)
        let result = transition(
            .awaitingDisarmChallenge(alarmKitID: alarm.id),
            .challengeCompleted(alarmKitID: alarm.id),
            alarm: alarm
        )

        XCTAssertEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]))
        // Persist BEFORE schedule: the reset snooze count must be visible when
        // the configuration is built (snooze button reappears on next ring).
        XCTAssertEqual(result.effects, [
            .persist(bookkept(alarm, lifecycleState: .scheduled)),
            .scheduleAlarmKit(alarmID: alarm.id),
        ])
    }

    func testChallengeCompletedBridgeReturnsToOverrideActive() {
        let bridgeID = UUID()
        let remainingBridgeID = UUID()
        let alarm = makeOverrideAlarm(bridgeAlarmIDs: [bridgeID, remainingBridgeID])

        let result = transition(
            .awaitingDisarmChallenge(alarmKitID: bridgeID),
            .challengeCompleted(alarmKitID: bridgeID),
            alarm: alarm
        )

        XCTAssertEqual(result.phase, .overrideActive(bridgeAlarmIDs: [remainingBridgeID]))
        XCTAssertEqual(result.effects, [
            .cancelAlarmKit(ids: [bridgeID]),
            .persist(bookkept(alarm, lifecycleState: .scheduled)),
        ])
    }

    func testChallengeCompletedOneShotDeleteAfterUseDeletes() {
        let alarm = makeAlarm(deleteAfterUse: true)
        let result = transition(
            .awaitingDisarmChallenge(alarmKitID: alarm.id),
            .challengeCompleted(alarmKitID: alarm.id),
            alarm: alarm
        )

        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: [alarm.id]), .deleteAlarm(alarm.id)])
    }

    func testChallengeCompletedKeptOneShotEmitsPersistDisabled() {
        let alarm = makeAlarm(deleteAfterUse: false, snoozeCount: 1)
        let result = transition(
            .awaitingDisarmChallenge(alarmKitID: alarm.id),
            .challengeCompleted(alarmKitID: alarm.id),
            alarm: alarm
        )

        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.effects, [
            .cancelAlarmKit(ids: [alarm.id]),
            .persist(bookkept(alarm, isEnabled: false, lifecycleState: .completed)),
        ])
    }

    func testChallengeCompletedNonMatchingIDIsNoOp() {
        let alarm = makeAlarm()
        let result = transition(
            .awaitingDisarmChallenge(alarmKitID: alarm.id),
            .challengeCompleted(alarmKitID: UUID()),
            alarm: alarm
        )

        XCTAssertEqual(result.phase, .awaitingDisarmChallenge(alarmKitID: alarm.id))
        XCTAssertEqual(result.effects, [])
    }

    // MARK: - Wake-check confirmed (R-7.7 branch priority)

    func testWakeCheckConfirmedOverrideWinsOverRepeating() {
        let bridgeIDs = [UUID(), UUID()]
        let alarm = makeOverrideAlarm(bridgeAlarmIDs: bridgeIDs)

        let result = transition(.awaitingWakeCheck, .wakeCheckConfirmed, alarm: alarm, settings: wakeCheckSettings)

        XCTAssertEqual(result.phase, .overrideActive(bridgeAlarmIDs: Set(bridgeIDs)))
        XCTAssertEqual(result.effects, [.persist(bookkept(alarm, lifecycleState: .scheduled))])
    }

    func testWakeCheckConfirmedRepeatingReschedulesAlarm() {
        let alarm = makeAlarm(repeatDays: [.monday, .friday], deleteAfterUse: false, snoozeCount: 3)
        let result = transition(.awaitingWakeCheck, .wakeCheckConfirmed, alarm: alarm, settings: wakeCheckSettings)

        XCTAssertEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]))
        XCTAssertEqual(result.effects, [
            .persist(bookkept(alarm, lifecycleState: .scheduled)),
            .scheduleAlarmKit(alarmID: alarm.id),
        ])
    }

    func testWakeCheckConfirmedOneShotDeleteAfterUseDeletes() {
        let alarm = makeAlarm(deleteAfterUse: true)
        let result = transition(.awaitingWakeCheck, .wakeCheckConfirmed, alarm: alarm, settings: wakeCheckSettings)

        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.effects, [.deleteAlarm(alarm.id)])
    }

    func testWakeCheckConfirmedNapDeletes() {
        let alarm = makeAlarm(type: .nap(NapConfig(durationMinutes: 30, pausedRemainingSeconds: nil)))
        let result = transition(.awaitingWakeCheck, .wakeCheckConfirmed, alarm: alarm, settings: wakeCheckSettings)

        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.effects, [.deleteAlarm(alarm.id)])
    }

    func testWakeCheckConfirmedTryOutDeletes() {
        var alarm = makeAlarm(deleteAfterUse: false, type: .tryOut)
        alarm.deleteAfterUse = false  // even without the flag, tryOut deletes
        let result = transition(.awaitingWakeCheck, .wakeCheckConfirmed, alarm: alarm, settings: wakeCheckSettings)

        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.effects, [.deleteAlarm(alarm.id)])
    }

    func testWakeCheckConfirmedKeptOneShotEmitsPersistDisabled() {
        let alarm = makeAlarm(deleteAfterUse: false, snoozeCount: 1)
        let result = transition(.awaitingWakeCheck, .wakeCheckConfirmed, alarm: alarm, settings: wakeCheckSettings)

        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.effects, [
            .persist(bookkept(alarm, isEnabled: false, lifecycleState: .completed)),
        ])
    }

    // MARK: - Override lifecycle (R-6)

    func testOverrideActivatedFromScheduled() {
        let alarm = makeAlarm(repeatDays: [.monday, .wednesday, .friday])
        let bridgeIDs: Set<UUID> = [UUID(), UUID(), UUID(), UUID(), UUID()]

        let result = transition(
            .scheduled(alarmKitIDs: [alarm.id]),
            .overrideActivated(bridgeAlarmIDs: bridgeIDs),
            alarm: alarm
        )

        XCTAssertEqual(result.phase, .overrideActive(bridgeAlarmIDs: bridgeIDs))
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: [alarm.id])])
    }

    func testOverrideActivatedFromIdleAlsoCancelsCanonical() {
        // Defensive arm: the phase can be a stale .idle after an AlarmKit read
        // failure; the canonical registration must still be cancelled.
        let alarm = makeAlarm(repeatDays: [.monday])
        let bridgeIDs: Set<UUID> = [UUID()]

        let result = transition(.idle, .overrideActivated(bridgeAlarmIDs: bridgeIDs), alarm: alarm)

        XCTAssertEqual(result.phase, .overrideActive(bridgeAlarmIDs: bridgeIDs))
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: [alarm.id])])
    }

    func testOverrideActivatedFromSnoozedCancelsSnoozedInstance() {
        // Skip-next on a snoozed alarm must kill the pending snoozed instance
        // (R-6.2 + R-5.4: the snoozed instance is registered under the same
        // canonical ID, but a snoozed BRIDGE would be a different ID).
        let alarm = makeAlarm(repeatDays: [.monday], snoozeCount: 1)
        let snoozedBridgeID = UUID()
        let bridgeIDs: Set<UUID> = [UUID(), UUID()]

        let result = transition(
            .snoozed(alarmKitID: snoozedBridgeID),
            .overrideActivated(bridgeAlarmIDs: bridgeIDs),
            alarm: alarm
        )

        XCTAssertEqual(result.phase, .overrideActive(bridgeAlarmIDs: bridgeIDs))
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: [snoozedBridgeID, alarm.id])])
    }

    func testOverrideRestoredCancelsBridgesAndSchedulesCanonical() {
        let alarm = makeAlarm(repeatDays: [.monday, .wednesday, .friday])
        let bridgeIDs: Set<UUID> = [UUID(), UUID(), UUID()]

        let result = transition(
            .overrideActive(bridgeAlarmIDs: bridgeIDs),
            .overrideRestored(bridgeAlarmIDs: bridgeIDs),
            alarm: alarm
        )

        XCTAssertEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]))
        XCTAssertEqual(result.effects, [
            .cancelAlarmKit(ids: bridgeIDs),
            .scheduleAlarmKit(alarmID: alarm.id),
        ])
    }

    func testOverrideRestoredWorksFromStalePhase() {
        // The event carries bridge IDs from the alarm model, so bridge alarms
        // are cancelled even when the in-memory phase is stale.
        let alarm = makeAlarm(repeatDays: [.monday])
        let bridgeIDs: Set<UUID> = [UUID(), UUID()]

        let result = transition(.idle, .overrideRestored(bridgeAlarmIDs: bridgeIDs), alarm: alarm)

        XCTAssertEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]))
        XCTAssertEqual(result.effects, [
            .cancelAlarmKit(ids: bridgeIDs),
            .scheduleAlarmKit(alarmID: alarm.id),
        ])
    }

    func testOverrideRestoredWithNoBridgesJustSchedules() {
        let alarm = makeAlarm(repeatDays: [.monday])
        let result = transition(.overrideActive(bridgeAlarmIDs: []), .overrideRestored(bridgeAlarmIDs: []), alarm: alarm)

        XCTAssertEqual(result.phase, .scheduled(alarmKitIDs: [alarm.id]))
        XCTAssertEqual(result.effects, [.scheduleAlarmKit(alarmID: alarm.id)])
    }

    // MARK: - Challenge completed with lost runtime phase
    // The UI completion is durable proof that a disarm was in progress even if
    // the transient phase was lost (app relaunch between stop and completion).

    func testChallengeCompletedOneShotDeleteAfterUseDeletesEvenIfRuntimePhaseWasLost() {
        let alarm = makeAlarm(deleteAfterUse: true)
        let result = transition(.idle, .challengeCompleted(alarmKitID: alarm.id), alarm: alarm)

        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: [alarm.id]), .deleteAlarm(alarm.id)])
    }

    func testChallengeCompletedWithWakeCheckDoesNotDeleteWhenRuntimePhaseWasLost() {
        let alarm = makeAlarm(deleteAfterUse: true)
        let result = transition(
            .idle,
            .challengeCompleted(alarmKitID: alarm.id),
            alarm: alarm,
            settings: wakeCheckSettings
        )

        XCTAssertEqual(result.phase, .awaitingWakeCheck)
        XCTAssertEqual(result.effects, [
            .cancelAlarmKit(ids: [alarm.id]),
            .persist(bookkept(alarm, lifecycleState: .awaitingWakeCheck)),
        ])
        XCTAssertFalse(result.effects.contains(.deleteAlarm(alarm.id)))
    }

    func testChallengeCompletedNoTaskFlowUsesSameDeleteAfterUsePolicy() {
        let settingsWithoutTasks = SharedAlarmSettings(
            snoozeEnabled: false,
            snoozeDurationMinutes: 5,
            maxSnoozes: 3,
            wakeUpCheckEnabled: false,
            wakeUpCheckDelayMinutes: 5,
            wakeUpCheckResponseTimeoutMinutes: 3,
            tasks: []
        )
        let alarm = makeAlarm(deleteAfterUse: true)
        let result = transition(
            .awaitingDisarmChallenge(alarmKitID: alarm.id),
            .challengeCompleted(alarmKitID: alarm.id),
            alarm: alarm,
            settings: settingsWithoutTasks
        )

        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.effects, [.cancelAlarmKit(ids: [alarm.id]), .deleteAlarm(alarm.id)])
    }

    // MARK: - Alarm list display during wake-check

    func testListDisplayHidesNonRepeatingDeleteAfterUseAlarmDuringWakeCheck() {
        let alarm = makeAlarm(deleteAfterUse: true)

        let presentation = AlarmListDisplayPolicy.presentation(
            for: alarm,
            hasActiveWakeCheckSession: true
        )

        XCTAssertEqual(presentation, .hide)
    }

    func testListDisplayShowsNonRepeatingKeptAlarmAsDisabledDuringWakeCheck() {
        let alarm = makeAlarm(deleteAfterUse: false)

        let presentation = AlarmListDisplayPolicy.presentation(
            for: alarm,
            hasActiveWakeCheckSession: true
        )

        guard case .show(let projectedAlarm, let isInteractive) = presentation else {
            return XCTFail("Expected projected disabled alarm")
        }
        XCTAssertFalse(projectedAlarm.isEnabled)
        XCTAssertEqual(projectedAlarm.lifecycleState, .completed)
        XCTAssertFalse(isInteractive)
    }

    func testListDisplayLeavesAlarmUnchangedWithoutWakeCheckSession() {
        let alarm = makeAlarm(deleteAfterUse: true)

        let presentation = AlarmListDisplayPolicy.presentation(
            for: alarm,
            hasActiveWakeCheckSession: false
        )

        XCTAssertEqual(presentation, .show(alarm: alarm, isInteractive: true))
    }
}
