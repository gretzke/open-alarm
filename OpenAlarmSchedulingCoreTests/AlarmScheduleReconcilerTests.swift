import XCTest
#if canImport(OpenAlarmSchedulingCore)
@testable import OpenAlarmSchedulingCore
#else
@testable import OpenAlarm
#endif

final class AlarmScheduleReconcilerTests: XCTestCase {
    func testSkipNextExpiredRestoresRecurringAtNextValidOccurrence() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let skipUntil = now.addingTimeInterval(-1)

        let desired = AlarmScheduleDesiredPlan(
            isRepeating: true,
            mode: .temporarySkip(until: skipUntil)
        )
        let actual = AlarmScheduleActualState(
            previous: .missing,
            current: .missing
        )

        let operations = AlarmScheduleReconciler.reconcile(
            desired: desired,
            actual: actual,
            now: now
        )

        XCTAssertEqual(
            operations,
            [
                .clearTemporarySkipAndEnableRecurring,
                .scheduleRecurringRestore
            ]
        )
    }

    func testModifyNextOnceTransitionRestoresRecurringSchedule() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let oneShotTrigger = now.addingTimeInterval(-30)

        let desired = AlarmScheduleDesiredPlan(
            isRepeating: true,
            mode: .temporaryOneShot(triggerDate: oneShotTrigger),
            nextTriggerOverrideDate: oneShotTrigger
        )
        let actual = AlarmScheduleActualState(
            previous: .alerting,
            current: .missing
        )

        let operations = AlarmScheduleReconciler.reconcile(
            desired: desired,
            actual: actual,
            now: now
        )

        XCTAssertEqual(
            operations,
            [
                .clearTemporaryOneShot,
                .scheduleRecurringRestore
            ]
        )
    }

    func testDuplicateFireCallbackHandlingIsIdempotentAfterFirstRestoreMutation() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let oneShotTrigger = now.addingTimeInterval(-60)

        let firstDesired = AlarmScheduleDesiredPlan(
            isRepeating: true,
            mode: .temporaryOneShot(triggerDate: oneShotTrigger),
            nextTriggerOverrideDate: oneShotTrigger
        )
        let firstActual = AlarmScheduleActualState(
            previous: .alerting,
            current: .missing
        )

        let firstOperations = AlarmScheduleReconciler.reconcile(
            desired: firstDesired,
            actual: firstActual,
            now: now
        )

        XCTAssertEqual(
            firstOperations,
            [
                .clearTemporaryOneShot,
                .scheduleRecurringRestore
            ]
        )

        // After the first reconciliation mutations are applied, mode returns to canonical recurring.
        let duplicateDesired = AlarmScheduleDesiredPlan(
            isRepeating: true,
            mode: .recurring,
            nextTriggerOverrideDate: nil
        )
        let duplicateActual = AlarmScheduleActualState(
            previous: .missing,
            current: .missing
        )

        let duplicateOperations = AlarmScheduleReconciler.reconcile(
            desired: duplicateDesired,
            actual: duplicateActual,
            now: now
        )

        XCTAssertTrue(duplicateOperations.isEmpty)
    }

    func testColdStartRecoveryFromPersistedOneShotModeRestoresRecurring() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let oneShotTrigger = now.addingTimeInterval(-120)

        let desired = AlarmScheduleDesiredPlan(
            isRepeating: true,
            mode: .temporaryOneShot(triggerDate: oneShotTrigger),
            nextTriggerOverrideDate: oneShotTrigger
        )
        let actual = AlarmScheduleActualState(
            previous: .missing,
            current: .missing
        )

        let operations = AlarmScheduleReconciler.reconcile(
            desired: desired,
            actual: actual,
            now: now
        )

        XCTAssertEqual(
            operations,
            [
                .clearTemporaryOneShot,
                .scheduleRecurringRestore
            ]
        )
    }

    func testStopIntentHookRoutesToAlarmScopedReconcile() {
        let alarmID = UUID(uuidString: "DCE8CB2E-01D8-4548-B03A-2A12F3A16DB1")!

        XCTAssertEqual(
            AlarmScheduleReconcileRouting.target(for: .stopIntent(alarmID)),
            .alarm(alarmID)
        )
    }

    func testSnoozeIntentHookRoutesToAlarmScopedReconcile() {
        let alarmID = UUID(uuidString: "FB0C589E-8D72-45B3-B16F-25FC774E5FF9")!

        XCTAssertEqual(
            AlarmScheduleReconcileRouting.target(for: .snoozeIntent(alarmID)),
            .alarm(alarmID)
        )
    }

    func testAppLaunchHookRoutesToAllAlarmsReconcile() {
        XCTAssertEqual(
            AlarmScheduleReconcileRouting.target(for: .appLaunch),
            .allAlarms
        )
    }

    func testReconcileHookRoutingIsIdempotent() {
        let alarmID = UUID(uuidString: "2D78DAD2-3D64-4B9E-A2A9-DCA6A743DF9F")!

        let stopFirst = AlarmScheduleReconcileRouting.target(for: .stopIntent(alarmID))
        let stopSecond = AlarmScheduleReconcileRouting.target(for: .stopIntent(alarmID))
        XCTAssertEqual(stopFirst, stopSecond)

        let snoozeFirst = AlarmScheduleReconcileRouting.target(for: .snoozeIntent(alarmID))
        let snoozeSecond = AlarmScheduleReconcileRouting.target(for: .snoozeIntent(alarmID))
        XCTAssertEqual(snoozeFirst, snoozeSecond)

        XCTAssertEqual(stopFirst, snoozeFirst)

        let launchFirst = AlarmScheduleReconcileRouting.target(for: .appLaunch)
        let launchSecond = AlarmScheduleReconcileRouting.target(for: .appLaunch)
        XCTAssertEqual(launchFirst, launchSecond)
    }

    func testDisableNextActivationUsesBridgeQueueAnchoredAtSecondCanonicalOccurrence() {
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 2, day: 28, hour: 6, minute: 0, calendar: calendar)

        let schedule = AlarmCanonicalScheduleSpec(
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            hour: 7,
            minute: 0,
            isEnabled: true
        )

        let activation = AlarmSchedulePlanner.activateTemporaryOverride(
            canonicalSchedule: schedule,
            intent: .disableNext,
            now: now,
            manualQueueDepth: 5,
            calendar: calendar
        )

        XCTAssertNotNil(activation)
        XCTAssertEqual(activation?.overrideState.kind, .disableNext)
        XCTAssertEqual(activation?.manualTriggerDates.count, 5)

        let expectedAnchor = makeUTCDate(year: 2026, month: 3, day: 1, hour: 7, minute: 0, calendar: calendar)
        XCTAssertEqual(activation?.overrideState.restoreAnchorDate, expectedAnchor)
        XCTAssertEqual(activation?.manualTriggerDates.first, expectedAnchor)
        XCTAssertTrue(AlarmSchedulePlanner.shouldRestoreRecurringSchedule(
            afterManualAlarmFiredAt: expectedAnchor,
            overrideState: activation!.overrideState
        ))
    }

    func testModifyNextEarlierSchedulesOverrideThenUsualAnchorAndRestoresOnSecondRing() {
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 2, day: 28, hour: 6, minute: 0, calendar: calendar)

        let schedule = AlarmCanonicalScheduleSpec(
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            hour: 8,
            minute: 0,
            isEnabled: true
        )

        let overrideDate = makeUTCDate(year: 2026, month: 2, day: 28, hour: 7, minute: 0, calendar: calendar)

        let activation = AlarmSchedulePlanner.activateTemporaryOverride(
            canonicalSchedule: schedule,
            intent: .modifyNext(triggerDate: overrideDate),
            now: now,
            manualQueueDepth: 5,
            calendar: calendar
        )

        XCTAssertNotNil(activation)
        XCTAssertEqual(activation?.overrideState.kind, .modifyNext)

        let expectedAnchor = makeUTCDate(year: 2026, month: 2, day: 28, hour: 8, minute: 0, calendar: calendar)
        XCTAssertEqual(activation?.overrideState.restoreAnchorDate, expectedAnchor)
        XCTAssertEqual(activation?.manualTriggerDates.prefix(2), [overrideDate, expectedAnchor])

        XCTAssertFalse(AlarmSchedulePlanner.shouldRestoreRecurringSchedule(
            afterManualAlarmFiredAt: overrideDate,
            overrideState: activation!.overrideState
        ))
        XCTAssertTrue(AlarmSchedulePlanner.shouldRestoreRecurringSchedule(
            afterManualAlarmFiredAt: expectedAnchor,
            overrideState: activation!.overrideState
        ))
    }

    func testModifyNextLaterRestoresWhenOverrideRings() {
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 2, day: 28, hour: 6, minute: 0, calendar: calendar)

        let schedule = AlarmCanonicalScheduleSpec(
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            hour: 8,
            minute: 0,
            isEnabled: true
        )

        let overrideDate = makeUTCDate(year: 2026, month: 2, day: 28, hour: 9, minute: 0, calendar: calendar)

        let activation = AlarmSchedulePlanner.activateTemporaryOverride(
            canonicalSchedule: schedule,
            intent: .modifyNext(triggerDate: overrideDate),
            now: now,
            manualQueueDepth: 5,
            calendar: calendar
        )

        XCTAssertNotNil(activation)
        XCTAssertEqual(activation?.manualTriggerDates.first, overrideDate)
        XCTAssertTrue(AlarmSchedulePlanner.shouldRestoreRecurringSchedule(
            afterManualAlarmFiredAt: overrideDate,
            overrideState: activation!.overrideState
        ))
    }

    func testTemporaryOverrideModesAreMutuallyExclusiveBySinglePersistedState() {
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 2, day: 28, hour: 6, minute: 0, calendar: calendar)

        let schedule = AlarmCanonicalScheduleSpec(
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            hour: 8,
            minute: 0,
            isEnabled: true
        )

        let disable = AlarmSchedulePlanner.activateTemporaryOverride(
            canonicalSchedule: schedule,
            intent: .disableNext,
            now: now,
            manualQueueDepth: 5,
            calendar: calendar
        )

        let modify = AlarmSchedulePlanner.activateTemporaryOverride(
            canonicalSchedule: schedule,
            intent: .modifyNext(triggerDate: now.addingTimeInterval(3600)),
            now: now,
            manualQueueDepth: 5,
            calendar: calendar
        )

        XCTAssertEqual(disable?.overrideState.kind, .disableNext)
        XCTAssertEqual(modify?.overrideState.kind, .modifyNext)
        XCTAssertNotEqual(disable?.overrideState.kind, modify?.overrideState.kind)
    }

    func testScheduleChangeSignatureClearsTemporaryOverrideState() {
        let previous = AlarmCanonicalScheduleSignature(
            spec: AlarmCanonicalScheduleSpec(
                weekdayNumbers: [2, 4, 6],
                hour: 8,
                minute: 15,
                isEnabled: true
            )
        )

        XCTAssertFalse(
            AlarmSchedulePlanner.shouldClearTemporaryOverride(previous: previous, next: previous)
        )

        XCTAssertTrue(
            AlarmSchedulePlanner.shouldClearTemporaryOverride(
                previous: previous,
                next: AlarmCanonicalScheduleSignature(
                    spec: AlarmCanonicalScheduleSpec(
                        weekdayNumbers: [2, 4, 6],
                        hour: 8,
                        minute: 45,
                        isEnabled: true
                    )
                )
            )
        )

        XCTAssertTrue(
            AlarmSchedulePlanner.shouldClearTemporaryOverride(
                previous: previous,
                next: AlarmCanonicalScheduleSignature(
                    spec: AlarmCanonicalScheduleSpec(
                        weekdayNumbers: [2, 4],
                        hour: 8,
                        minute: 15,
                        isEnabled: true
                    )
                )
            )
        )

        XCTAssertTrue(
            AlarmSchedulePlanner.shouldClearTemporaryOverride(
                previous: previous,
                next: AlarmCanonicalScheduleSignature(
                    spec: AlarmCanonicalScheduleSpec(
                        weekdayNumbers: [2, 4, 6],
                        hour: 8,
                        minute: 15,
                        isEnabled: false
                    )
                )
            )
        )
    }

    func testFallbackQueueRebuildAfterMissedAnchorProducesFutureBridges() {
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 2, day: 28, hour: 6, minute: 0, calendar: calendar)

        let schedule = AlarmCanonicalScheduleSpec(
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            hour: 7,
            minute: 0,
            isEnabled: true
        )

        let activation = AlarmSchedulePlanner.activateTemporaryOverride(
            canonicalSchedule: schedule,
            intent: .disableNext,
            now: now,
            manualQueueDepth: 5,
            calendar: calendar
        )

        XCTAssertNotNil(activation)

        let afterMissedAnchor = makeUTCDate(year: 2026, month: 3, day: 1, hour: 8, minute: 0, calendar: calendar)
        let rebuilt = AlarmSchedulePlanner.desiredManualTriggerDates(
            canonicalSchedule: schedule,
            overrideState: activation!.overrideState,
            now: afterMissedAnchor,
            manualQueueDepth: 5,
            calendar: calendar
        )

        XCTAssertEqual(rebuilt.count, 5)
        XCTAssertTrue(rebuilt.allSatisfy { $0 > afterMissedAnchor })
    }

    func testWakeUpCheckDelayOptionsExposeExpectedUserChoices() {
        XCTAssertEqual(
            WakeUpCheckTimingPolicy.checkDelayOptionsMinutes,
            [1, 3, 5, 10, 15, 20, 30, 45, 60]
        )
    }

    func testWakeUpCheckDelayIntervalUsesFiveSecondsForDebugSentinel() {
        XCTAssertEqual(
            WakeUpCheckTimingPolicy.checkDelayInterval(
                for: WakeUpCheckTimingPolicy.debugFiveSecondSentinelMinutes
            ),
            5
        )
    }

    func testWakeUpCheckDelayIntervalUsesMinuteValueForNormalSetting() {
        XCTAssertEqual(
            WakeUpCheckTimingPolicy.checkDelayInterval(for: 5),
            300
        )
    }

    func testWakeUpCheckDelayClampingKeepsDebugSentinelButClampsInvalidValues() {
        XCTAssertEqual(
            WakeUpCheckTimingPolicy.clampCheckDelayMinutes(
                WakeUpCheckTimingPolicy.debugFiveSecondSentinelMinutes
            ),
            0
        )
        XCTAssertEqual(WakeUpCheckTimingPolicy.clampCheckDelayMinutes(-2), 1)
        XCTAssertEqual(WakeUpCheckTimingPolicy.clampCheckDelayMinutes(120), 60)
    }

    func testWakeUpCheckResponseTimeoutOptionsExposeExpectedUserChoices() {
        XCTAssertEqual(
            WakeUpCheckTimingPolicy.responseTimeoutOptionsMinutes,
            [1, 2, 3, 5, 10, 20]
        )
    }

    func testWakeUpCheckResponseTimeoutIntervalUsesFiveSecondsForDebugSentinel() {
        XCTAssertEqual(
            WakeUpCheckTimingPolicy.responseTimeoutInterval(
                for: WakeUpCheckTimingPolicy.debugFiveSecondSentinelMinutes
            ),
            5
        )
    }

    func testWakeUpCheckResponseTimeoutIntervalUsesMinuteValueForNormalSetting() {
        XCTAssertEqual(
            WakeUpCheckTimingPolicy.responseTimeoutInterval(for: 3),
            180
        )
    }

    func testWakeUpCheckResponseTimeoutNormalizationKeepsDebugSentinelButClampsInvalidValues() {
        XCTAssertEqual(
            WakeUpCheckTimingPolicy.normalizeResponseTimeoutMinutes(
                WakeUpCheckTimingPolicy.debugFiveSecondSentinelMinutes
            ),
            0
        )
        XCTAssertEqual(WakeUpCheckTimingPolicy.normalizeResponseTimeoutMinutes(-2), 1)
    }

    private func fixedUTCGregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func makeUTCDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        calendar: Calendar
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)

        return calendar.date(from: components)!
    }
}
