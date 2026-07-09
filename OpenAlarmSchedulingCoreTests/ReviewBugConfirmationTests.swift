import XCTest
@testable import OpenAlarmSchedulingCore

final class ReviewBugConfirmationTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return calendar.date(from: comps)!
    }

    private func assertStrictlyAscending(_ dates: [Date], file: StaticString = #filePath, line: UInt = #line) {
        for index in 1..<dates.count {
            XCTAssertLessThan(dates[index - 1], dates[index], file: file, line: line)
        }
    }

    private func makeRepeatingOverrideAlarm(
        alarmID: UUID,
        bridgeAlarmIDs: [UUID],
        snoozeCount: Int = 2
    ) -> AlarmDefinition {
        AlarmDefinition(
            id: alarmID,
            trigger: .time(hour: 22, minute: 0),
            recurrence: .weekly(AlarmWeekday.allCases),
            type: .regular,
            deleteAfterUse: false,
            settingsMode: .useDefault,
            isEnabled: true,
            activeOverride: OverrideState(
                kind: .modifyNext,
                bridgeAlarmIDs: bridgeAlarmIDs,
                restoreAnchorDate: now
            ),
            snoozeCount: snoozeCount,
            lifecycleState: .scheduled,
            createdAt: now,
            updatedAt: now
        )
    }

    private func bookkept(
        _ alarm: AlarmDefinition,
        lifecycleState: AlarmLifecycleState
    ) -> AlarmDefinition {
        var updated = alarm
        updated.snoozeCount = 0
        updated.lifecycleState = lifecycleState
        updated.updatedAt = now
        return updated
    }

    private func transition(
        _ current: AlarmSchedulingPhase,
        _ event: AlarmEvent,
        alarm: AlarmDefinition
    ) -> AlarmStateMachine.TransitionResult {
        AlarmStateMachine.transition(
            current: current,
            event: event,
            alarm: alarm,
            resolvedSettings: .featureDefaults,
            now: now
        )
    }

    // MARK: - D-review-1: modify-next can bridge into the past

    func testModifyNextEarlierSameDayKeepsFirstBridgeAfterReference() {
        // Daily 22:00 alarm, reference is the same day at 09:00, user modifies
        // the next occurrence to 08:30. Correct behavior requires the first
        // bridge fire date to remain strictly after the reference date.
        let reference = date(year: 2026, month: 1, day: 15, hour: 9, minute: 0)

        let result = BridgeDateCalculator.bridgeDates(
            hour: 22,
            minute: 0,
            repeatDays: AlarmWeekday.allCases,
            overrideKind: .modifyNext,
            modifiedTime: (hour: 8, minute: 30),
            referenceDate: reference,
            calendar: calendar
        )

        XCTAssertEqual(result.bridgeDates.count, 5)
        XCTAssertEqual(result.bridgeDates[0], date(year: 2026, month: 1, day: 16, hour: 8, minute: 30))
        XCTAssertGreaterThan(result.bridgeDates[0], reference)
        assertStrictlyAscending(result.bridgeDates)
    }

    func testModifyNextSparseRecurrenceEarlierSameDayKeepsFirstBridgeAfterReference() {
        // Weekly Monday-only 22:00 alarm, reference is Monday at 09:00, user
        // modifies the next occurrence to 08:30. The first modified bridge must
        // still be strictly after the reference, even for sparse recurrences.
        let reference = date(year: 2026, month: 1, day: 12, hour: 9, minute: 0)

        let result = BridgeDateCalculator.bridgeDates(
            hour: 22,
            minute: 0,
            repeatDays: [.monday],
            overrideKind: .modifyNext,
            modifiedTime: (hour: 8, minute: 30),
            referenceDate: reference,
            calendar: calendar
        )

        XCTAssertEqual(result.bridgeDates.count, 5)
        XCTAssertEqual(result.bridgeDates[0], date(year: 2026, month: 1, day: 13, hour: 8, minute: 30))
        XCTAssertGreaterThan(result.bridgeDates[0], reference)
        assertStrictlyAscending(result.bridgeDates)
    }

    func testModifyNextLaterSameDayKeepsFirstBridgeAfterReference() {
        // Same harness as the expected-failure case, but modifying 22:00 to
        // 23:00 should produce a same-day bridge that is still in the future.
        let reference = date(year: 2026, month: 1, day: 15, hour: 9, minute: 0)

        let result = BridgeDateCalculator.bridgeDates(
            hour: 22,
            minute: 0,
            repeatDays: AlarmWeekday.allCases,
            overrideKind: .modifyNext,
            modifiedTime: (hour: 23, minute: 0),
            referenceDate: reference,
            calendar: calendar
        )

        let expectedBridge = date(year: 2026, month: 1, day: 15, hour: 23, minute: 0)
        XCTAssertEqual(result.bridgeDates[0], expectedBridge)
        XCTAssertGreaterThan(result.bridgeDates[0], reference)

        let bridgeDay = calendar.dateComponents([.year, .month, .day], from: result.bridgeDates[0])
        let referenceDay = calendar.dateComponents([.year, .month, .day], from: reference)
        XCTAssertEqual(bridgeDay, referenceDay)
    }

    // MARK: - D-review-2: rebuilt disarm phase must preserve bridge identity

    /*
     AlarmStore.rebuildRuntimePhases is outside the SPM package, but these
     tests pin the reachable state-machine mechanism behind the store-side bug:
     an active override only takes the override-bridge branch when the completed
     AlarmKit ID is one of activeOverride.bridgeAlarmIDs. The store now resolves
     the rebuilt phase's AlarmKit ID from the pending-disarm queue; rebuilding
     with alarm.id instead makes the same completion take the repeating branch.
     */

    func testDisarmCompletionWithBridgeID_takesOverrideBranch() {
        let alarmID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let bridgeID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let remainingBridgeID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let alarm = makeRepeatingOverrideAlarm(alarmID: alarmID, bridgeAlarmIDs: [bridgeID, remainingBridgeID])

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
        XCTAssertFalse(result.effects.contains(.scheduleAlarmKit(alarmID: alarmID)))
    }

    func testDisarmCompletionWithCanonicalIDWhileOverrideActive_divergesFromBridgeBranch() {
        let alarmID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let bridgeID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let remainingBridgeID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let alarm = makeRepeatingOverrideAlarm(alarmID: alarmID, bridgeAlarmIDs: [bridgeID, remainingBridgeID])

        let result = transition(
            .awaitingDisarmChallenge(alarmKitID: alarmID),
            .challengeCompleted(alarmKitID: alarmID),
            alarm: alarm
        )

        XCTAssertEqual(result.phase, .scheduled(alarmKitIDs: [alarmID]))
        XCTAssertEqual(result.effects, [
            .persist(bookkept(alarm, lifecycleState: .scheduled)),
            .scheduleAlarmKit(alarmID: alarmID),
        ])
        XCTAssertFalse(result.effects.contains(.cancelAlarmKit(ids: [bridgeID])))
        XCTAssertFalse(result.effects.contains(.cancelAlarmKit(ids: [remainingBridgeID])))
    }
}
