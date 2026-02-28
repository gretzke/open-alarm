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

    func testTemporaryOverrideRegressionMatrixCoversCallbackAndAppReopenReconcilePaths() {
        let calendar = fixedUTCGregorianCalendar()

        let now = makeUTCDate(year: 2026, month: 3, day: 2, hour: 6, minute: 0, calendar: calendar)
        let canonicalToday = makeUTCDate(year: 2026, month: 3, day: 2, hour: 9, minute: 0, calendar: calendar)
        let canonicalTomorrow = makeUTCDate(year: 2026, month: 3, day: 3, hour: 9, minute: 0, calendar: calendar)
        let canonicalDayAfterTomorrow = makeUTCDate(year: 2026, month: 3, day: 4, hour: 9, minute: 0, calendar: calendar)

        let modifyEarlierOverride = makeUTCDate(year: 2026, month: 3, day: 2, hour: 8, minute: 0, calendar: calendar)
        let modifyLaterOverride = makeUTCDate(year: 2026, month: 3, day: 2, hour: 10, minute: 0, calendar: calendar)

        let schedule = AlarmCanonicalScheduleSpec(
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            hour: 9,
            minute: 0,
            isEnabled: true
        )

        struct Scenario {
            let name: String
            let intent: AlarmTemporaryOverrideIntent
            let expectedKind: AlarmTemporaryScheduleOverrideKind
            let expectedRestoreAnchorDate: Date
            let expectedInitialFirstTrigger: Date
            let disallowedInitialTrigger: Date?
            let completionDateFromCallback: Date
            let completionDateFromColdStartReconcile: Date
            let expectedConsumesOverrideDateOnCompletion: Bool
            let expectedRestoresRecurringOnCompletion: Bool
            let appReopenReferenceDate: Date
            let expectedFirstTriggerAfterAppReopenRebuild: Date
            let disallowedRebuiltTrigger: Date?
        }

        let scenarios: [Scenario] = [
            Scenario(
                name: "modify-next earlier (09:00 -> 08:00)",
                intent: .modifyNext(triggerDate: modifyEarlierOverride),
                expectedKind: .modifyNext,
                expectedRestoreAnchorDate: canonicalToday,
                expectedInitialFirstTrigger: modifyEarlierOverride,
                disallowedInitialTrigger: canonicalToday,
                completionDateFromCallback: modifyEarlierOverride,
                completionDateFromColdStartReconcile: modifyEarlierOverride,
                expectedConsumesOverrideDateOnCompletion: true,
                expectedRestoresRecurringOnCompletion: false,
                appReopenReferenceDate: makeUTCDate(year: 2026, month: 3, day: 2, hour: 8, minute: 5, calendar: calendar),
                expectedFirstTriggerAfterAppReopenRebuild: canonicalTomorrow,
                disallowedRebuiltTrigger: canonicalToday
            ),
            Scenario(
                name: "modify-next later (09:00 -> 10:00)",
                intent: .modifyNext(triggerDate: modifyLaterOverride),
                expectedKind: .modifyNext,
                expectedRestoreAnchorDate: canonicalToday,
                expectedInitialFirstTrigger: modifyLaterOverride,
                disallowedInitialTrigger: canonicalToday,
                completionDateFromCallback: modifyLaterOverride,
                completionDateFromColdStartReconcile: modifyLaterOverride,
                expectedConsumesOverrideDateOnCompletion: true,
                expectedRestoresRecurringOnCompletion: true,
                appReopenReferenceDate: makeUTCDate(year: 2026, month: 3, day: 2, hour: 10, minute: 5, calendar: calendar),
                expectedFirstTriggerAfterAppReopenRebuild: canonicalTomorrow,
                disallowedRebuiltTrigger: nil
            ),
            Scenario(
                name: "disable-next / skip-next",
                intent: .disableNext,
                expectedKind: .disableNext,
                expectedRestoreAnchorDate: canonicalTomorrow,
                expectedInitialFirstTrigger: canonicalTomorrow,
                disallowedInitialTrigger: canonicalToday,
                completionDateFromCallback: canonicalTomorrow,
                completionDateFromColdStartReconcile: canonicalTomorrow,
                expectedConsumesOverrideDateOnCompletion: false,
                expectedRestoresRecurringOnCompletion: true,
                appReopenReferenceDate: makeUTCDate(year: 2026, month: 3, day: 3, hour: 9, minute: 5, calendar: calendar),
                expectedFirstTriggerAfterAppReopenRebuild: canonicalDayAfterTomorrow,
                disallowedRebuiltTrigger: nil
            )
        ]

        for scenario in scenarios {
            let activation = AlarmSchedulePlanner.activateTemporaryOverride(
                canonicalSchedule: schedule,
                intent: scenario.intent,
                now: now,
                manualQueueDepth: 5,
                calendar: calendar
            )

            XCTAssertNotNil(activation, "\(scenario.name): activation should succeed")
            guard let activation else { continue }

            XCTAssertEqual(
                activation.overrideState.kind,
                scenario.expectedKind,
                "\(scenario.name): persisted override kind should match intent"
            )
            XCTAssertEqual(
                activation.overrideState.restoreAnchorDate,
                scenario.expectedRestoreAnchorDate,
                "\(scenario.name): restore anchor should match canonical expectations"
            )
            XCTAssertEqual(
                activation.manualTriggerDates.first,
                scenario.expectedInitialFirstTrigger,
                "\(scenario.name): initial queue head should be deterministic"
            )

            if let disallowedInitialTrigger = scenario.disallowedInitialTrigger {
                XCTAssertFalse(
                    activation.manualTriggerDates.contains(disallowedInitialTrigger),
                    "\(scenario.name): initial queue should not include disallowed canonical slot"
                )
            }

            let consumedFromCallback = AlarmSchedulePlanner.shouldConsumeOverrideDate(
                afterManualAlarmFiredAt: scenario.completionDateFromCallback,
                overrideState: activation.overrideState
            )
            XCTAssertEqual(
                consumedFromCallback,
                scenario.expectedConsumesOverrideDateOnCompletion,
                "\(scenario.name): callback completion should consume override date as expected"
            )

            let restoredFromCallback = AlarmSchedulePlanner.shouldRestoreRecurringSchedule(
                afterManualAlarmFiredAt: scenario.completionDateFromCallback,
                overrideState: activation.overrideState
            )
            XCTAssertEqual(
                restoredFromCallback,
                scenario.expectedRestoresRecurringOnCompletion,
                "\(scenario.name): callback completion restore decision should match expectation"
            )

            let consumedFromColdStart = AlarmSchedulePlanner.shouldConsumeOverrideDate(
                afterManualAlarmFiredAt: scenario.completionDateFromColdStartReconcile,
                overrideState: activation.overrideState
            )
            XCTAssertEqual(
                consumedFromColdStart,
                scenario.expectedConsumesOverrideDateOnCompletion,
                "\(scenario.name): app-reopen reconcile should consume override date consistently"
            )

            let restoredFromColdStart = AlarmSchedulePlanner.shouldRestoreRecurringSchedule(
                afterManualAlarmFiredAt: scenario.completionDateFromColdStartReconcile,
                overrideState: activation.overrideState
            )
            XCTAssertEqual(
                restoredFromColdStart,
                scenario.expectedRestoresRecurringOnCompletion,
                "\(scenario.name): app-reopen reconcile restore decision should match callback semantics"
            )

            let rebuilt = AlarmSchedulePlanner.desiredManualTriggerDates(
                canonicalSchedule: schedule,
                overrideState: activation.overrideState,
                now: scenario.appReopenReferenceDate,
                manualQueueDepth: 5,
                calendar: calendar
            )
            XCTAssertEqual(
                rebuilt.first,
                scenario.expectedFirstTriggerAfterAppReopenRebuild,
                "\(scenario.name): app-reopen reconcile should rebuild deterministic future bridge queue"
            )

            if let disallowedRebuiltTrigger = scenario.disallowedRebuiltTrigger {
                XCTAssertFalse(
                    rebuilt.contains(disallowedRebuiltTrigger),
                    "\(scenario.name): rebuilt queue should not reintroduce disallowed canonical slot"
                )
            }
        }
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

    func testModifyNextEarlierMonFriSchedulesOnlyImmediateOverrideThenFutureCanonicalBridge() {
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 3, day: 1, hour: 12, minute: 0, calendar: calendar) // Sunday

        let schedule = AlarmCanonicalScheduleSpec(
            weekdayNumbers: [2, 6],
            hour: 9,
            minute: 0,
            isEnabled: true
        )

        let mondayOverride = makeUTCDate(year: 2026, month: 3, day: 2, hour: 8, minute: 0, calendar: calendar)
        let mondayCanonical = makeUTCDate(year: 2026, month: 3, day: 2, hour: 9, minute: 0, calendar: calendar)
        let fridayCanonical = makeUTCDate(year: 2026, month: 3, day: 6, hour: 9, minute: 0, calendar: calendar)

        let activation = AlarmSchedulePlanner.activateTemporaryOverride(
            canonicalSchedule: schedule,
            intent: .modifyNext(triggerDate: mondayOverride),
            now: now,
            manualQueueDepth: 5,
            calendar: calendar
        )

        XCTAssertNotNil(activation)
        XCTAssertEqual(activation?.overrideState.kind, .modifyNext)
        XCTAssertEqual(activation?.overrideState.restoreAnchorDate, mondayCanonical)
        XCTAssertEqual(activation?.manualTriggerDates.first, mondayOverride)
        XCTAssertEqual(activation?.manualTriggerDates.dropFirst().first, fridayCanonical)
        XCTAssertFalse(activation!.manualTriggerDates.contains(mondayCanonical))
    }

    func testModifyNextEarlierOverrideIsConsumedOnFirstEligibleRing() {
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 3, day: 1, hour: 12, minute: 0, calendar: calendar)

        let schedule = AlarmCanonicalScheduleSpec(
            weekdayNumbers: [2, 6],
            hour: 9,
            minute: 0,
            isEnabled: true
        )

        let mondayOverride = makeUTCDate(year: 2026, month: 3, day: 2, hour: 8, minute: 0, calendar: calendar)

        let activation = AlarmSchedulePlanner.activateTemporaryOverride(
            canonicalSchedule: schedule,
            intent: .modifyNext(triggerDate: mondayOverride),
            now: now,
            manualQueueDepth: 5,
            calendar: calendar
        )

        XCTAssertNotNil(activation)
        XCTAssertTrue(AlarmSchedulePlanner.shouldConsumeOverrideDate(
            afterManualAlarmFiredAt: mondayOverride,
            overrideState: activation!.overrideState
        ))
        XCTAssertFalse(AlarmSchedulePlanner.shouldRestoreRecurringSchedule(
            afterManualAlarmFiredAt: mondayOverride,
            overrideState: activation!.overrideState
        ))
    }

    func testModifyNextEarlierReconcileAfterConsumedOverrideDoesNotReintroduceSameDayCanonical() {
        let calendar = fixedUTCGregorianCalendar()

        let mondayCanonical = makeUTCDate(year: 2026, month: 3, day: 2, hour: 9, minute: 0, calendar: calendar)
        let mondayAfterOverride = makeUTCDate(year: 2026, month: 3, day: 2, hour: 8, minute: 30, calendar: calendar)
        let fridayCanonical = makeUTCDate(year: 2026, month: 3, day: 6, hour: 9, minute: 0, calendar: calendar)

        let schedule = AlarmCanonicalScheduleSpec(
            weekdayNumbers: [2, 6],
            hour: 9,
            minute: 0,
            isEnabled: true
        )

        let consumedState = AlarmTemporaryScheduleOverride(
            kind: .modifyNext,
            overrideDate: nil,
            restoreAnchorDate: mondayCanonical,
            skippedCanonicalDate: nil,
            activatedAt: makeUTCDate(year: 2026, month: 3, day: 1, hour: 12, minute: 0, calendar: calendar)
        )

        let rebuilt = AlarmSchedulePlanner.desiredManualTriggerDates(
            canonicalSchedule: schedule,
            overrideState: consumedState,
            now: mondayAfterOverride,
            manualQueueDepth: 5,
            calendar: calendar
        )

        XCTAssertEqual(rebuilt.first, fridayCanonical)
        XCTAssertFalse(rebuilt.contains(mondayCanonical))
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

    func testIntegrationModifyNextEarlierDoesNotKeepCanonical0900RuntimeAfterActivation() {
        let calendar = fixedUTCGregorianCalendar()
        let sundayNoon = makeUTCDate(year: 2026, month: 3, day: 1, hour: 12, minute: 0, calendar: calendar)
        let mondayOverride = makeUTCDate(year: 2026, month: 3, day: 2, hour: 8, minute: 0, calendar: calendar)
        let mondayCanonical = makeUTCDate(year: 2026, month: 3, day: 2, hour: 9, minute: 0, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "6A3E2EA9-0A32-4559-B89A-FD53BB568A0A")!,
            configReferenceID: UUID(uuidString: "70901326-0880-4D24-9D70-ECFCFB139FBD")!,
            weekdayNumbers: [2, 6],
            hour: 9,
            minute: 0
        )

        harness.activateModifyNext(triggerDate: mondayOverride, now: sundayNoon)

        let overrideEntry = harness.alarm.manualScheduleQueue.first(where: { $0.triggerDate == mondayOverride })
        XCTAssertNotNil(overrideEntry, "modify-next should materialize explicit 08:00 manual runtime alarm")
        XCTAssertTrue(
            harness.runtime.containsRuntimeAlarm(id: overrideEntry!.id),
            "08:00 runtime alarm must be present immediately after modify-next activation"
        )

        XCTAssertFalse(
            harness.runtime.containsRuntimeAlarm(id: harness.alarm.id),
            "canonical recurring runtime alarm must be absent while temporary override queue is active"
        )

        XCTAssertFalse(
            harness.runtime.containsRuntimeAlarmScheduled(for: mondayCanonical),
            "no stale 09:00 runtime entry should remain after modify-next activation"
        )
    }

    func testIntegrationModifyNextEarlierStopIntentThenCallbackPlusAppReopenLeavesOverrideStale() throws {
        let calendar = fixedUTCGregorianCalendar()
        let sundayNoon = makeUTCDate(year: 2026, month: 3, day: 1, hour: 12, minute: 0, calendar: calendar)
        let mondayOverride = makeUTCDate(year: 2026, month: 3, day: 2, hour: 8, minute: 0, calendar: calendar)
        let fridayCanonical = makeUTCDate(year: 2026, month: 3, day: 6, hour: 9, minute: 0, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "11EACB96-3AEF-4632-AF2C-8BA5CC543D4A")!,
            configReferenceID: UUID(uuidString: "AB5A9F7F-98B4-42E8-B57D-8A3731F58D2A")!,
            weekdayNumbers: [2, 6],
            hour: 9,
            minute: 0
        )

        harness.activateModifyNext(triggerDate: mondayOverride, now: sundayNoon)

        let overrideRuntimeID = try XCTUnwrap(
            harness.alarm.manualScheduleQueue.first(where: { $0.triggerDate == mondayOverride })?.id
        )

        // Alarm callback marks override runtime as alerting first.
        harness.runtime.setState(.alerting, for: overrideRuntimeID)
        harness.applyRemoteSnapshot(referenceDate: mondayOverride)

        // Stop intent reconciliation targets runtime ID before callback stream reports completion.
        harness.reconcile(trigger: .stopIntent(overrideRuntimeID), referenceDate: mondayOverride.addingTimeInterval(5))

        // Callback + app-open snapshots now only see future bridge IDs.
        harness.runtime.removeRuntimeAlarm(id: overrideRuntimeID)
        harness.applyRemoteSnapshot(referenceDate: mondayOverride.addingTimeInterval(10))

        var reopened = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            persistedAlarm: harness.alarm,
            runtime: harness.runtime
        )

        reopened.applyRemoteSnapshot(referenceDate: mondayOverride.addingTimeInterval(5 * 60))
        reopened.reconcileAll(referenceDate: mondayOverride.addingTimeInterval(5 * 60))

        XCTAssertEqual(
            reopened.alarm.manualScheduleQueue.first?.triggerDate,
            fridayCanonical,
            "after override completion, Friday should remain as next bridge runtime"
        )

        XCTAssertNil(
            reopened.alarm.nextTriggerOverrideDate,
            "override display field should be cleared after stop callback + app reopen path"
        )
        XCTAssertNil(
            reopened.alarm.temporaryScheduleOverride?.overrideDate,
            "persisted override date should not stay stale once override runtime completed"
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

private struct AlarmStoreOverrideIntegrationHarness {
    private let manualOverrideQueueDepth = AlarmSchedulePlanner.defaultManualQueueDepth

    private(set) var calendar: Calendar
    private(set) var alarm: HarnessAlarm
    var runtime: RuntimeAlarmHarness
    private var lastKnownAlarmState: [UUID: AlarmScheduleRemoteState] = [:]
    private var remoteStates: [UUID: AlarmScheduleRemoteState] = [:]

    init(
        calendar: Calendar,
        alarmID: UUID,
        configReferenceID: UUID,
        weekdayNumbers: [Int],
        hour: Int,
        minute: Int
    ) {
        self.calendar = calendar
        self.alarm = HarnessAlarm(
            id: alarmID,
            scheduleConfigReferenceID: configReferenceID,
            weekdayNumbers: weekdayNumbers,
            hour: hour,
            minute: minute
        )
        self.runtime = RuntimeAlarmHarness()
    }

    init(
        calendar: Calendar,
        persistedAlarm: HarnessAlarm,
        runtime: RuntimeAlarmHarness
    ) {
        self.calendar = calendar
        self.alarm = persistedAlarm
        self.runtime = runtime
    }

    mutating func activateModifyNext(triggerDate: Date, now: Date) {
        guard let activation = AlarmSchedulePlanner.activateTemporaryOverride(
            canonicalSchedule: alarm.canonicalScheduleSpec,
            intent: .modifyNext(triggerDate: triggerDate),
            now: now,
            manualQueueDepth: manualOverrideQueueDepth,
            calendar: calendar
        ) else {
            XCTFail("expected modify-next activation to succeed")
            return
        }

        alarm.isEnabled = true
        alarm.nextTriggerOverrideDate = triggerDate
        alarm.skipNextUntilDate = nil
        alarm.temporaryScheduleOverride = activation.overrideState
        alarm.manualScheduleQueue = buildManualQueueEntries(
            triggerDates: activation.manualTriggerDates,
            restoreAnchorDate: activation.overrideState.restoreAnchorDate,
            configReferenceID: alarm.scheduleConfigReferenceID,
            overrideDate: activation.overrideState.overrideDate
        )

        reconcileSchedule(target: .alarm(alarm.id), referenceDate: now)
    }

    mutating func reconcile(trigger: AlarmScheduleReconcileTrigger, referenceDate: Date) {
        reconcileSchedule(
            target: AlarmScheduleReconcileRouting.target(for: trigger),
            referenceDate: referenceDate
        )
    }

    mutating func reconcileAll(referenceDate: Date) {
        reconcileSchedule(target: .allAlarms, referenceDate: referenceDate)
    }

    mutating func applyRemoteSnapshot(referenceDate: Date) {
        applyRemoteAlarms(runtime.snapshot(), referenceDate: referenceDate)
    }

    private mutating func reconcileSchedule(
        target: AlarmScheduleReconcileTarget,
        referenceDate: Date
    ) {
        switch target {
        case let .alarm(runtimeAlarmID):
            guard let alarmID = owningAlarmID(for: runtimeAlarmID) else {
                return
            }
            reconcileSchedulingForAlarm(alarmID, referenceDate: referenceDate)

        case .allAlarms:
            reconcileSchedulingForAlarm(alarm.id, referenceDate: referenceDate)
        }
    }

    private func owningAlarmID(for runtimeAlarmID: UUID) -> UUID? {
        if alarm.id == runtimeAlarmID {
            return alarm.id
        }

        return alarm.manualScheduleQueue.contains(where: { $0.id == runtimeAlarmID }) ? alarm.id : nil
    }

    private mutating func reconcileSchedulingForAlarm(_ alarmID: UUID, referenceDate: Date) {
        guard alarm.id == alarmID else {
            return
        }

        if let overrideState = alarm.temporaryScheduleOverride,
           alarm.isRepeating {
            let desiredDates = AlarmSchedulePlanner.desiredManualTriggerDates(
                canonicalSchedule: alarm.canonicalScheduleSpec,
                overrideState: overrideState,
                now: referenceDate,
                manualQueueDepth: manualOverrideQueueDepth,
                calendar: calendar
            )

            if desiredDates.isEmpty {
                alarm.temporaryScheduleOverride = nil
                alarm.manualScheduleQueue.removeAll()
                alarm.skipNextUntilDate = nil
                alarm.nextTriggerOverrideDate = nil
                alarm.isEnabled = true
            } else {
                var existingByDate: [Date: AlarmManualScheduleEntry] = [:]
                for entry in alarm.manualScheduleQueue where existingByDate[entry.triggerDate] == nil {
                    existingByDate[entry.triggerDate] = entry
                }

                let rebuiltQueue: [AlarmManualScheduleEntry] = desiredDates.map { date in
                    if let existing = existingByDate[date] {
                        return existing
                    }

                    return AlarmManualScheduleEntry(
                        id: UUID(),
                        triggerDate: date,
                        restoreAnchorDate: overrideState.restoreAnchorDate,
                        configReferenceID: alarm.scheduleConfigReferenceID,
                        role: (overrideState.overrideDate != nil && date == overrideState.overrideDate) ? .overrideTrigger : .canonicalBridge
                    )
                }

                let staleManualIDs = Set(alarm.manualScheduleQueue.map(\.id))
                    .subtracting(Set(rebuiltQueue.map(\.id)))
                cancelRuntimeAlarms(ids: staleManualIDs)

                alarm.manualScheduleQueue = rebuiltQueue

                runtime.stop(id: alarm.id)
                runtime.cancel(id: alarm.id)
                lastKnownAlarmState.removeValue(forKey: alarm.id)

                for manual in alarm.manualScheduleQueue where manual.triggerDate > referenceDate.addingTimeInterval(-1) {
                    runtime.schedule(id: manual.id, triggerDate: manual.triggerDate)
                    lastKnownAlarmState[manual.id] = .scheduled
                }

                remoteStates[alarm.id] = alarm.manualScheduleQueue.isEmpty ? nil : .scheduled
            }
        }

        if alarm.temporaryScheduleOverride == nil {
            if !alarm.manualScheduleQueue.isEmpty {
                cancelRuntimeAlarms(ids: Set(alarm.manualScheduleQueue.map(\.id)))
                alarm.manualScheduleQueue.removeAll()
            }

            if alarm.isEnabled {
                runtime.schedule(
                    id: alarm.id,
                    triggerDate: AlarmSchedulePlanner.nextCanonicalOccurrence(
                        after: referenceDate,
                        schedule: alarm.canonicalScheduleSpec,
                        calendar: calendar
                    )
                )
                lastKnownAlarmState[alarm.id] = .scheduled
                remoteStates[alarm.id] = .scheduled
            } else {
                runtime.stop(id: alarm.id)
                runtime.cancel(id: alarm.id)
                lastKnownAlarmState.removeValue(forKey: alarm.id)
                remoteStates.removeValue(forKey: alarm.id)
            }
        }
    }

    private mutating func applyRemoteAlarms(
        _ incoming: [RuntimeAlarmHarness.RuntimeAlarm],
        referenceDate: Date
    ) {
        let remoteByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })

        guard let overrideState = alarm.temporaryScheduleOverride else {
            return
        }

        guard !alarm.manualScheduleQueue.isEmpty else {
            alarm.temporaryScheduleOverride = nil
            alarm.nextTriggerOverrideDate = nil
            alarm.skipNextUntilDate = nil
            alarm.isEnabled = true
            return
        }

        var shouldRestoreRecurring = false
        var shouldConsumeOverrideDate = false
        var hasManualAlertingState = false

        for manual in alarm.manualScheduleQueue {
            let previousState = lastKnownAlarmState[manual.id]
            let currentState = remoteByID[manual.id]?.state

            if let currentState {
                lastKnownAlarmState[manual.id] = currentState
            } else {
                lastKnownAlarmState.removeValue(forKey: manual.id)
            }

            if currentState == .alerting {
                hasManualAlertingState = true
            }

            let completedFromFireTransition = previousState == .alerting && currentState != .alerting
            let completedWhileColdStart = currentState == nil && manual.triggerDate <= referenceDate

            if completedFromFireTransition || completedWhileColdStart {
                if AlarmSchedulePlanner.shouldConsumeOverrideDate(
                    afterManualAlarmFiredAt: manual.triggerDate,
                    overrideState: overrideState
                ) {
                    shouldConsumeOverrideDate = true
                }

                if AlarmSchedulePlanner.shouldRestoreRecurringSchedule(
                    afterManualAlarmFiredAt: manual.triggerDate,
                    overrideState: overrideState
                ) {
                    shouldRestoreRecurring = true
                }
            }
        }

        runtime.stop(id: alarm.id)
        runtime.cancel(id: alarm.id)
        lastKnownAlarmState.removeValue(forKey: alarm.id)

        if shouldConsumeOverrideDate,
           !shouldRestoreRecurring,
           var mutableOverrideState = alarm.temporaryScheduleOverride {
            if alarm.nextTriggerOverrideDate != nil {
                alarm.nextTriggerOverrideDate = nil
            }

            if mutableOverrideState.overrideDate != nil {
                mutableOverrideState.overrideDate = nil
                alarm.temporaryScheduleOverride = mutableOverrideState
            }
        }

        if shouldRestoreRecurring {
            let staleManualIDs = Set(alarm.manualScheduleQueue.map(\.id))
            for id in staleManualIDs {
                runtime.stop(id: id)
                runtime.cancel(id: id)
                lastKnownAlarmState.removeValue(forKey: id)
            }

            alarm.temporaryScheduleOverride = nil
            alarm.manualScheduleQueue.removeAll()
            alarm.nextTriggerOverrideDate = nil
            alarm.skipNextUntilDate = nil
            alarm.isEnabled = true
            remoteStates.removeValue(forKey: alarm.id)
        } else {
            remoteStates[alarm.id] = hasManualAlertingState ? .alerting : .scheduled
        }
    }

    private func buildManualQueueEntries(
        triggerDates: [Date],
        restoreAnchorDate: Date,
        configReferenceID: UUID,
        overrideDate: Date?
    ) -> [AlarmManualScheduleEntry] {
        triggerDates
            .sorted()
            .map { triggerDate in
                AlarmManualScheduleEntry(
                    id: UUID(),
                    triggerDate: triggerDate,
                    restoreAnchorDate: restoreAnchorDate,
                    configReferenceID: configReferenceID,
                    role: (overrideDate != nil && triggerDate == overrideDate) ? .overrideTrigger : .canonicalBridge
                )
            }
    }

    private mutating func cancelRuntimeAlarms(ids: Set<UUID>) {
        guard !ids.isEmpty else {
            return
        }

        for id in ids {
            runtime.stop(id: id)
            runtime.cancel(id: id)
            lastKnownAlarmState.removeValue(forKey: id)
            remoteStates.removeValue(forKey: id)
        }
    }
}

private struct HarnessAlarm {
    var id: UUID
    var scheduleConfigReferenceID: UUID
    var weekdayNumbers: [Int]
    var hour: Int
    var minute: Int

    var isEnabled: Bool = true
    var nextTriggerOverrideDate: Date?
    var skipNextUntilDate: Date?
    var temporaryScheduleOverride: AlarmTemporaryScheduleOverride?
    var manualScheduleQueue: [AlarmManualScheduleEntry] = []

    var isRepeating: Bool {
        !weekdayNumbers.isEmpty
    }

    var canonicalScheduleSpec: AlarmCanonicalScheduleSpec {
        AlarmCanonicalScheduleSpec(
            weekdayNumbers: weekdayNumbers,
            hour: hour,
            minute: minute,
            isEnabled: true
        )
    }
}

private struct RuntimeAlarmHarness {
    struct RuntimeAlarm: Equatable {
        var id: UUID
        var state: AlarmScheduleRemoteState
        var triggerDate: Date?
    }

    private(set) var byID: [UUID: RuntimeAlarm] = [:]

    mutating func schedule(id: UUID, triggerDate: Date?) {
        byID[id] = RuntimeAlarm(id: id, state: .scheduled, triggerDate: triggerDate)
    }

    mutating func stop(id: UUID) {
        guard var current = byID[id] else {
            return
        }

        if current.state == .alerting {
            current.state = .scheduled
            byID[id] = current
        }
    }

    mutating func cancel(id: UUID) {
        byID.removeValue(forKey: id)
    }

    mutating func setState(_ state: AlarmScheduleRemoteState, for id: UUID) {
        if var current = byID[id] {
            current.state = state
            byID[id] = current
        } else {
            byID[id] = RuntimeAlarm(id: id, state: state, triggerDate: nil)
        }
    }

    mutating func removeRuntimeAlarm(id: UUID) {
        byID.removeValue(forKey: id)
    }

    func containsRuntimeAlarm(id: UUID) -> Bool {
        byID[id] != nil
    }

    func containsRuntimeAlarmScheduled(for triggerDate: Date) -> Bool {
        byID.values.contains { $0.triggerDate == triggerDate }
    }

    func snapshot() -> [RuntimeAlarm] {
        Array(byID.values)
    }
}
