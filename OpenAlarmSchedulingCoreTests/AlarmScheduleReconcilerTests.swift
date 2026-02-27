import XCTest
@testable import OpenAlarmSchedulingCore

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
}
