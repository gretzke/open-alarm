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

        harness.seedCanonicalRuntime(triggerDate: mondayCanonical)
        XCTAssertTrue(
            harness.runtime.containsRuntimeAlarm(id: harness.alarm.id),
            "precondition: canonical recurring runtime alarm should exist before modify-next activation"
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

    func testIntegrationModifyNextEarlierStopIntentThenCallbackSuppressesCanonical0900SameDayRing() throws {
        let calendar = fixedUTCGregorianCalendar()
        let sundayNoon = makeUTCDate(year: 2026, month: 3, day: 1, hour: 12, minute: 0, calendar: calendar)
        let mondayOverride = makeUTCDate(year: 2026, month: 3, day: 2, hour: 8, minute: 0, calendar: calendar)
        let mondayCanonical = makeUTCDate(year: 2026, month: 3, day: 2, hour: 9, minute: 0, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "11EACB96-3AEF-4632-AF2C-8BA5CC543D4A")!,
            configReferenceID: UUID(uuidString: "AB5A9F7F-98B4-42E8-B57D-8A3731F58D2A")!,
            weekdayNumbers: [2, 6],
            hour: 9,
            minute: 0
        )

        harness.seedCanonicalRuntime(triggerDate: mondayCanonical)
        harness.activateModifyNext(triggerDate: mondayOverride, now: sundayNoon)

        let overrideRuntimeID = try XCTUnwrap(
            harness.alarm.manualScheduleQueue.first(where: { $0.triggerDate == mondayOverride })?.id
        )

        let firedAtOverride = harness.runtime.fireDue(at: mondayOverride)
        XCTAssertEqual(
            firedAtOverride,
            [overrideRuntimeID],
            "08:00 override runtime should be the only alarm that enters alerting"
        )

        harness.applyRemoteSnapshot(referenceDate: mondayOverride)

        // Stop intent reconciliation targets runtime ID before callback stream reports completion.
        harness.reconcile(trigger: .stopIntent(overrideRuntimeID), referenceDate: mondayOverride.addingTimeInterval(5))

        // Callback snapshot no longer includes the consumed override runtime.
        harness.runtime.removeRuntimeAlarm(id: overrideRuntimeID)
        harness.applyRemoteSnapshot(referenceDate: mondayOverride.addingTimeInterval(10))
        harness.reconcileAll(referenceDate: mondayOverride.addingTimeInterval(10))

        let firedAtCanonical = harness.runtime.fireDue(at: mondayCanonical)
        XCTAssertFalse(
            firedAtCanonical.contains(harness.alarm.id),
            "canonical 09:00 must be suppressed after the 08:00 override completed"
        )

        XCTAssertFalse(
            harness.runtime.containsRuntimeAlarmScheduled(for: mondayCanonical),
            "same-day canonical 09:00 runtime slot should stay absent after override callback path"
        )
    }

    func testIntegrationModifyNextEarlierBugReproWhenOverrideRuntimeIsDroppedAndCanonicalCancelNoops() throws {
        let calendar = fixedUTCGregorianCalendar()
        let sundayNoon = makeUTCDate(year: 2026, month: 3, day: 1, hour: 12, minute: 0, calendar: calendar)
        let mondayOverride = makeUTCDate(year: 2026, month: 3, day: 2, hour: 8, minute: 0, calendar: calendar)
        let mondayCanonical = makeUTCDate(year: 2026, month: 3, day: 2, hour: 9, minute: 0, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "5EC8BB26-09E4-4388-B8D3-64508EE268E8")!,
            configReferenceID: UUID(uuidString: "B6FA4DF6-AF9F-4E51-9D37-BDECBEC572B4")!,
            weekdayNumbers: [2, 6],
            hour: 9,
            minute: 0
        )

        // Missing runtime factor in previous harness: preexisting canonical runtime can survive
        // if runtime stop/cancel operations no-op and override scheduling silently drops.
        harness.seedCanonicalRuntime(triggerDate: mondayCanonical)
        harness.runtime.addCancelNoOpID(harness.alarm.id)
        harness.runtime.addDroppedScheduleTriggerDate(mondayOverride)

        harness.activateModifyNext(triggerDate: mondayOverride, now: sundayNoon)

        let overrideRuntimeID = try XCTUnwrap(
            harness.alarm.manualScheduleQueue.first(where: { $0.triggerDate == mondayOverride })?.id
        )

        let firedAtOverride = harness.runtime.fireDue(at: mondayOverride)
        XCTAssertTrue(
            firedAtOverride.contains(overrideRuntimeID),
            "BUG REPRO: expected override runtime to fire at 08:00, but it never entered alerting."
        )

        harness.applyRemoteSnapshot(referenceDate: mondayOverride.addingTimeInterval(60))
        harness.reconcileAll(referenceDate: mondayOverride.addingTimeInterval(60))

        let firedAtCanonical = harness.runtime.fireDue(at: mondayCanonical)
        XCTAssertFalse(
            firedAtCanonical.contains(harness.alarm.id),
            "BUG REPRO: canonical 09:00 fired even though modify-next override should suppress same-day canonical ring."
        )
    }

    func testPhase1ReconcileBarriersRunInABCOrderForOverrideQueueRebuild() throws {
        let calendar = fixedUTCGregorianCalendar()
        let sundayNoon = makeUTCDate(year: 2026, month: 3, day: 1, hour: 12, minute: 0, calendar: calendar)
        let mondayOverride = makeUTCDate(year: 2026, month: 3, day: 2, hour: 8, minute: 0, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "0F5A5CDA-37D1-4E34-9E32-AD2F17D4EFB5")!,
            configReferenceID: UUID(uuidString: "1DBA8D8A-7D39-42D2-A8B5-75DA6A2F7A95")!,
            weekdayNumbers: [2, 6],
            hour: 9,
            minute: 0
        )

        harness.activateModifyNext(triggerDate: mondayOverride, now: sundayNoon)

        let overrideRuntimeID = try XCTUnwrap(
            harness.alarm.manualScheduleQueue.first(where: { $0.triggerDate == mondayOverride })?.id
        )

        _ = harness.runtime.fireDue(at: mondayOverride)
        harness.applyRemoteSnapshot(referenceDate: mondayOverride)

        // Callback completion arrives as "missing" after stop/cancel.
        harness.runtime.removeRuntimeAlarm(id: overrideRuntimeID)
        harness.applyRemoteSnapshot(referenceDate: mondayOverride.addingTimeInterval(10))

        harness.resetReconcileBarrierTrace()
        harness.reconcileAll(referenceDate: mondayOverride.addingTimeInterval(10))

        XCTAssertEqual(harness.reconcileBarrierTrace, ["A", "B:commit", "C"])
    }

    func testPhase1CallbackRestoreDefersManualCleanupToReconcileBarrierC() throws {
        let calendar = fixedUTCGregorianCalendar()
        let sundayNoon = makeUTCDate(year: 2026, month: 3, day: 1, hour: 12, minute: 0, calendar: calendar)
        let mondayOverrideLater = makeUTCDate(year: 2026, month: 3, day: 2, hour: 10, minute: 0, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "C2AC0F2A-80F6-49B7-A03A-D86D0536F68A")!,
            configReferenceID: UUID(uuidString: "A93707DF-8E1B-4F42-8886-E2D2353A463F")!,
            weekdayNumbers: [2, 6],
            hour: 9,
            minute: 0
        )

        harness.activateModifyNext(triggerDate: mondayOverrideLater, now: sundayNoon)

        let overrideRuntimeID = try XCTUnwrap(
            harness.alarm.manualScheduleQueue.first(where: { $0.triggerDate == mondayOverrideLater })?.id
        )

        harness.runtime.removeRuntimeAlarm(id: overrideRuntimeID)
        harness.applyRemoteSnapshot(referenceDate: mondayOverrideLater.addingTimeInterval(60))

        XCTAssertNil(harness.alarm.temporaryScheduleOverride)
        XCTAssertTrue(harness.alarm.manualScheduleQueue.contains(where: { $0.id == overrideRuntimeID }))
        XCTAssertFalse(harness.runtime.containsRuntimeAlarm(id: harness.alarm.id))

        harness.resetReconcileBarrierTrace()
        harness.reconcileAll(referenceDate: mondayOverrideLater.addingTimeInterval(60))

        XCTAssertEqual(harness.reconcileBarrierTrace, ["A", "B:commit", "C"])
        XCTAssertTrue(harness.alarm.manualScheduleQueue.isEmpty)
        XCTAssertFalse(harness.runtime.containsRuntimeAlarm(id: overrideRuntimeID))
        XCTAssertTrue(harness.runtime.containsRuntimeAlarm(id: harness.alarm.id))
    }

    func testPhase1DisableNextActivationSuppressesCanonicalRuntimeAndKeepsManualBridgeOnly() throws {
        let calendar = fixedUTCGregorianCalendar()
        let sundayNoon = makeUTCDate(year: 2026, month: 3, day: 1, hour: 12, minute: 0, calendar: calendar)
        let mondayCanonical = makeUTCDate(year: 2026, month: 3, day: 2, hour: 7, minute: 0, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "8D95D5C9-C05A-4D47-B89D-6D308662497D")!,
            configReferenceID: UUID(uuidString: "F3B44552-86BE-4FEC-845B-327D336A3CF7")!,
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            hour: 7,
            minute: 0
        )

        harness.seedCanonicalRuntime(triggerDate: mondayCanonical)
        harness.activateDisableNext(now: sundayNoon)

        XCTAssertEqual(harness.alarm.temporaryScheduleOverride?.kind, .disableNext)
        XCTAssertFalse(harness.runtime.containsRuntimeAlarm(id: harness.alarm.id))

        let firstManual = try XCTUnwrap(harness.alarm.manualScheduleQueue.first)
        XCTAssertTrue(harness.runtime.containsRuntimeAlarm(id: firstManual.id))
        XCTAssertFalse(harness.runtime.containsRuntimeAlarmScheduled(for: mondayCanonical))
    }

    // MARK: - Foreground reconcile skip-when-healthy regression

    func testForegroundReconcileDoesNotResetCountdownAlarm() {
        // Regression test: when the app is open, the reconcile loop fires on
        // every AlarmKit state change.  If an alarm is in countdown (imminent
        // firing), reconcile must NOT re-schedule it -- doing so resets the
        // countdown and prevents the alarm from ever reaching alerting.
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 3, day: 4, hour: 6, minute: 59, calendar: calendar)
        let canonicalTrigger = makeUTCDate(year: 2026, month: 3, day: 4, hour: 7, minute: 0, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "AAAA1111-2222-3333-4444-555566667777")!,
            configReferenceID: UUID(uuidString: "BBBB1111-2222-3333-4444-555566667777")!,
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            hour: 7,
            minute: 0
        )

        // Seed the alarm in runtime with .scheduled state (normal initial scheduling).
        harness.seedCanonicalRuntime(triggerDate: canonicalTrigger)
        XCTAssertTrue(harness.runtime.containsRuntimeAlarm(id: harness.alarm.id))

        // Simulate AlarmKit transitioning the alarm to .countdown (1 minute before fire).
        harness.runtime.setState(.countdown, for: harness.alarm.id)
        XCTAssertEqual(harness.runtime.byID[harness.alarm.id]?.state, .countdown)

        // Record the schedule call count before reconcile.
        let scheduleCountBefore = harness.runtime.scheduleCallCount

        // Run reconcile (as triggered by foreground alarmUpdates callback).
        harness.reconcileAll(referenceDate: now)

        // The alarm must still be in .countdown -- reconcile should have skipped it.
        XCTAssertEqual(
            harness.runtime.byID[harness.alarm.id]?.state,
            .countdown,
            "Reconcile must not reset a countdown alarm back to scheduled"
        )

        // Verify no additional schedule() call was made for this alarm.
        XCTAssertEqual(
            harness.runtime.scheduleCallCount,
            scheduleCountBefore,
            "Reconcile should not re-arm an alarm that is already in countdown"
        )
    }

    func testForegroundReconcileDoesNotRescheduleAlertingAlarm() {
        // Regression test: when the alarm is actively ringing (.alerting), the
        // reconcile loop (fired by the same AlarmKit callback) must NOT re-arm
        // it. Re-arming immediately silences the audible alert.
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 3, day: 4, hour: 7, minute: 0, calendar: calendar)
        let canonicalTrigger = makeUTCDate(year: 2026, month: 3, day: 4, hour: 7, minute: 0, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "EEEE1111-2222-3333-4444-555566667777")!,
            configReferenceID: UUID(uuidString: "FFFF1111-2222-3333-4444-555566667777")!,
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            hour: 7,
            minute: 0
        )

        // Seed and then simulate AlarmKit transitioning the alarm to .alerting.
        harness.seedCanonicalRuntime(triggerDate: canonicalTrigger)
        harness.runtime.setState(.alerting, for: harness.alarm.id)
        XCTAssertEqual(harness.runtime.byID[harness.alarm.id]?.state, .alerting)

        let scheduleCountBefore = harness.runtime.scheduleCallCount

        // Run reconcile (triggered by foreground alarmUpdates callback on state change).
        harness.reconcileAll(referenceDate: now)

        // The alarm must still be in .alerting -- reconcile should not have touched it.
        XCTAssertEqual(
            harness.runtime.byID[harness.alarm.id]?.state,
            .alerting,
            "Reconcile must not re-arm an alerting alarm (would silence the audible alert)"
        )

        XCTAssertEqual(
            harness.runtime.scheduleCallCount,
            scheduleCountBefore,
            "Reconcile should not call schedule() on an alarm that is already alerting"
        )
    }

    func testForegroundReconcileDoesNotReschedulePausedAlarm() {
        // Regression test: a paused (snoozed) alarm must not be re-armed by
        // reconcile, which would discard the snooze window.
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 3, day: 4, hour: 7, minute: 1, calendar: calendar)
        let canonicalTrigger = makeUTCDate(year: 2026, month: 3, day: 4, hour: 7, minute: 0, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "ABAB1111-2222-3333-4444-555566667777")!,
            configReferenceID: UUID(uuidString: "CDCD1111-2222-3333-4444-555566667777")!,
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            hour: 7,
            minute: 0
        )

        // Seed and then simulate AlarmKit transitioning the alarm to .paused (snoozed).
        harness.seedCanonicalRuntime(triggerDate: canonicalTrigger)
        harness.runtime.setState(.paused, for: harness.alarm.id)
        XCTAssertEqual(harness.runtime.byID[harness.alarm.id]?.state, .paused)

        let scheduleCountBefore = harness.runtime.scheduleCallCount

        harness.reconcileAll(referenceDate: now)

        // The alarm must remain paused -- reconcile should not have re-armed it.
        XCTAssertEqual(
            harness.runtime.byID[harness.alarm.id]?.state,
            .paused,
            "Reconcile must not re-arm a paused (snoozed) alarm"
        )

        XCTAssertEqual(
            harness.runtime.scheduleCallCount,
            scheduleCountBefore,
            "Reconcile should not call schedule() on an alarm that is already paused"
        )
    }

    func testForegroundReconcileDoesRearmMissingAlarm() {
        // Complementary test: if an alarm is NOT in runtime (e.g. after a
        // crash/restart), reconcile MUST re-schedule it.
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 3, day: 4, hour: 6, minute: 0, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "CCCC1111-2222-3333-4444-555566667777")!,
            configReferenceID: UUID(uuidString: "DDDD1111-2222-3333-4444-555566667777")!,
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            hour: 7,
            minute: 0
        )

        // Alarm is enabled but has no runtime entry (cold start / crash recovery).
        XCTAssertFalse(harness.runtime.containsRuntimeAlarm(id: harness.alarm.id))

        harness.reconcileAll(referenceDate: now)

        // Reconcile should have created a runtime entry.
        XCTAssertTrue(
            harness.runtime.containsRuntimeAlarm(id: harness.alarm.id),
            "Reconcile must re-arm an alarm that is missing from runtime"
        )
    }

    func testForegroundReconcileDoesRearmScheduledAlarmAfterEdit() {
        // Regression test for the inverse regression: when the user edits the
        // alarm (new trigger time/config), CRUD reconcile must overwrite the
        // stale `.scheduled` runtime entry with the new schedule.
        //
        // `.scheduled` IS in the healthy guard (prevents busy re-arm loop from
        // callbacks), but CRUD uses `forceRearm: true` to bypass the guard for
        // `.scheduled` only, ensuring edited alarms get their new config applied.
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 3, day: 4, hour: 6, minute: 0, calendar: calendar)
        let staleOldTrigger = makeUTCDate(year: 2026, month: 3, day: 4, hour: 7, minute: 0, calendar: calendar)
        let newTrigger = makeUTCDate(year: 2026, month: 3, day: 4, hour: 8, minute: 0, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "EFEF1111-2222-3333-4444-555566667777")!,
            configReferenceID: UUID(uuidString: "A1A11111-2222-3333-4444-555566667777")!,
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            // Alarm config is now 08:00 (user edited it after it was already scheduled at 07:00)
            hour: 8,
            minute: 0
        )

        // Seed a stale runtime entry at the OLD time (07:00) as `.scheduled`.
        harness.runtime.schedule(id: harness.alarm.id, triggerDate: staleOldTrigger)
        XCTAssertEqual(harness.runtime.byID[harness.alarm.id]?.state, .scheduled)
        XCTAssertEqual(harness.runtime.byID[harness.alarm.id]?.triggerDate, staleOldTrigger)

        let scheduleCountBefore = harness.runtime.scheduleCallCount

        // CRUD reconcile (forceRearm: true) should detect the stale scheduled entry and re-arm at 08:00.
        harness.reconcileForCRUD(alarmID: harness.alarm.id, referenceDate: now)

        XCTAssertGreaterThan(
            harness.runtime.scheduleCallCount,
            scheduleCountBefore,
            "CRUD reconcile must call schedule() to overwrite a stale .scheduled entry after alarm edit"
        )

        // The runtime trigger date must now reflect the updated config (08:00).
        XCTAssertEqual(
            harness.runtime.byID[harness.alarm.id]?.triggerDate,
            newTrigger,
            "Runtime trigger must be updated to the new alarm time after edit"
        )
    }

    // MARK: - Regression tests: callback reconcile must not stomp non-canonical schedules

    func testCallbackReconcileDoesNotOverwriteScheduledAlarm() {
        // Regression test for regressions 1 & 4: the alarmUpdates callback
        // triggers reconcileAllSchedules which must NOT re-arm a .scheduled
        // alarm. The busy re-arm loop prevented alarms from ever reaching
        // .countdown → .alerting.
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 3, day: 5, hour: 6, minute: 0, calendar: calendar)
        let canonicalTrigger = makeUTCDate(year: 2026, month: 3, day: 5, hour: 7, minute: 0, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "11111111-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
            configReferenceID: UUID(uuidString: "22222222-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            hour: 7,
            minute: 0
        )

        harness.seedCanonicalRuntime(triggerDate: canonicalTrigger)
        XCTAssertEqual(harness.runtime.byID[harness.alarm.id]?.state, .scheduled)

        let scheduleCountBefore = harness.runtime.scheduleCallCount

        // Simulate callback-triggered reconcile (forceRearm: false).
        harness.reconcileAll(referenceDate: now)

        // The alarm must remain .scheduled without being re-armed.
        XCTAssertEqual(
            harness.runtime.byID[harness.alarm.id]?.state,
            .scheduled,
            "Callback reconcile must not re-arm a .scheduled alarm"
        )
        XCTAssertEqual(
            harness.runtime.scheduleCallCount,
            scheduleCountBefore,
            "Callback reconcile should not call schedule() on an already-.scheduled alarm"
        )
    }

    func testCRUDReconcileReArmsScheduledAlarmWithForceRearm() {
        // Verify that CRUD operations (forceRearm: true) DO re-arm a .scheduled
        // alarm so edits take effect.
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 3, day: 5, hour: 6, minute: 0, calendar: calendar)
        let staleOldTrigger = makeUTCDate(year: 2026, month: 3, day: 5, hour: 7, minute: 0, calendar: calendar)
        let newTrigger = makeUTCDate(year: 2026, month: 3, day: 5, hour: 9, minute: 0, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "33333333-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
            configReferenceID: UUID(uuidString: "44444444-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            hour: 9,
            minute: 0
        )

        harness.runtime.schedule(id: harness.alarm.id, triggerDate: staleOldTrigger)
        XCTAssertEqual(harness.runtime.byID[harness.alarm.id]?.triggerDate, staleOldTrigger)

        let scheduleCountBefore = harness.runtime.scheduleCallCount

        // CRUD reconcile (forceRearm: true) should re-arm.
        harness.reconcileForCRUD(alarmID: harness.alarm.id, referenceDate: now)

        XCTAssertGreaterThan(
            harness.runtime.scheduleCallCount,
            scheduleCountBefore,
            "CRUD reconcile must re-arm a .scheduled alarm to apply new config"
        )
        XCTAssertEqual(
            harness.runtime.byID[harness.alarm.id]?.triggerDate,
            newTrigger,
            "CRUD reconcile must update trigger date to new config"
        )
    }

    func testSnoozeScheduleNotOverwrittenByCallbackReconcile() {
        // Regression test for regression 2: after SnoozeIntent schedules the
        // alarm at snooze time, the callback-triggered reconcile must NOT
        // overwrite the snooze schedule with the canonical schedule.
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 3, day: 5, hour: 7, minute: 0, calendar: calendar)
        let snoozeTrigger = makeUTCDate(year: 2026, month: 3, day: 5, hour: 7, minute: 5, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "55555555-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
            configReferenceID: UUID(uuidString: "66666666-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            hour: 7,
            minute: 0
        )

        // Simulate: alarm was snoozed, now scheduled at snooze time.
        harness.runtime.schedule(id: harness.alarm.id, triggerDate: snoozeTrigger)
        XCTAssertEqual(harness.runtime.byID[harness.alarm.id]?.state, .scheduled)
        XCTAssertEqual(harness.runtime.byID[harness.alarm.id]?.triggerDate, snoozeTrigger)

        let scheduleCountBefore = harness.runtime.scheduleCallCount

        // Callback reconcile must NOT overwrite snooze schedule.
        harness.reconcileAll(referenceDate: now)

        XCTAssertEqual(
            harness.runtime.byID[harness.alarm.id]?.triggerDate,
            snoozeTrigger,
            "Callback reconcile must not overwrite snooze schedule with canonical schedule"
        )
        XCTAssertEqual(
            harness.runtime.scheduleCallCount,
            scheduleCountBefore,
            "Callback reconcile should not call schedule() on a snoozed alarm in .scheduled state"
        )
    }

    func testRecurringAlarmScheduledStateNotResetByCallbackReconcile() {
        // Regression test for regression 4: recurring alarm re-armed after
        // firing must not be continuously re-armed by callback reconcile.
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 3, day: 5, hour: 7, minute: 1, calendar: calendar)
        let nextCanonical = makeUTCDate(year: 2026, month: 3, day: 6, hour: 7, minute: 0, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "77777777-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
            configReferenceID: UUID(uuidString: "88888888-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            hour: 7,
            minute: 0
        )

        // After firing, recurring alarm is re-armed for the next day.
        harness.runtime.schedule(id: harness.alarm.id, triggerDate: nextCanonical)
        XCTAssertEqual(harness.runtime.byID[harness.alarm.id]?.state, .scheduled)

        let scheduleCountBefore = harness.runtime.scheduleCallCount

        // Simulate multiple callback reconciles (as happens in production).
        for _ in 0..<5 {
            harness.reconcileAll(referenceDate: now)
        }

        XCTAssertEqual(
            harness.runtime.scheduleCallCount,
            scheduleCountBefore,
            "Callback reconcile must not re-arm a recurring alarm that is already .scheduled"
        )
        XCTAssertEqual(
            harness.runtime.byID[harness.alarm.id]?.triggerDate,
            nextCanonical,
            "Trigger date must remain at next canonical occurrence"
        )
    }

    func testForceRearmDoesNotBypassCountdownGuard() {
        // Safety: forceRearm must only bypass .scheduled, not .countdown/.alerting/.paused.
        let calendar = fixedUTCGregorianCalendar()
        let now = makeUTCDate(year: 2026, month: 3, day: 5, hour: 6, minute: 59, calendar: calendar)
        let canonicalTrigger = makeUTCDate(year: 2026, month: 3, day: 5, hour: 7, minute: 0, calendar: calendar)

        var harness = AlarmStoreOverrideIntegrationHarness(
            calendar: calendar,
            alarmID: UUID(uuidString: "99999999-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
            configReferenceID: UUID(uuidString: "AAAAAAAA-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
            weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
            hour: 7,
            minute: 0
        )

        harness.seedCanonicalRuntime(triggerDate: canonicalTrigger)
        harness.runtime.setState(.countdown, for: harness.alarm.id)

        let scheduleCountBefore = harness.runtime.scheduleCallCount

        // Even with forceRearm, .countdown must not be re-armed.
        harness.reconcileForCRUD(alarmID: harness.alarm.id, referenceDate: now)

        XCTAssertEqual(
            harness.runtime.byID[harness.alarm.id]?.state,
            .countdown,
            "forceRearm must not bypass .countdown guard"
        )
        XCTAssertEqual(
            harness.runtime.scheduleCallCount,
            scheduleCountBefore,
            "forceRearm must not cause schedule() call for .countdown alarm"
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

    func testWakeUpCheckCoordinatorStopIntentPolicyMatchesPipelineRequirements() {
        XCTAssertTrue(
            WakeUpCheckCoordinator.shouldEnqueuePipelineOnStopIntent(
                wakeUpCheckEnabledForAlarm: true,
                hasActiveSession: false
            )
        )
        XCTAssertTrue(
            WakeUpCheckCoordinator.shouldEnqueuePipelineOnStopIntent(
                wakeUpCheckEnabledForAlarm: false,
                hasActiveSession: true
            )
        )
        XCTAssertFalse(
            WakeUpCheckCoordinator.shouldEnqueuePipelineOnStopIntent(
                wakeUpCheckEnabledForAlarm: false,
                hasActiveSession: false
            )
        )
        XCTAssertTrue(WakeUpCheckCoordinator.wakeCheckAlarmsDisableSnooze)
    }

    func testWakeUpCheckCoordinatorClearsPendingStartAfterImmediateStopIntentArmingSuccess() {
        let alarmID = UUID(uuidString: "A0EE4E5F-7331-46D0-B531-7AB1AFC57E07")!
        let siblingAlarmID = UUID(uuidString: "00EBC0E6-B6F0-4783-B73B-2224BE465D55")!
        let pendingStartIDs: Set<UUID> = [alarmID, siblingAlarmID]

        XCTAssertEqual(
            WakeUpCheckCoordinator.pendingStartIDsAfterImmediateStopIntentArming(
                pendingStartIDs: pendingStartIDs,
                alarmID: alarmID,
                didArmImmediately: true
            ),
            Set([siblingAlarmID])
        )

        XCTAssertEqual(
            WakeUpCheckCoordinator.pendingStartIDsAfterImmediateStopIntentArming(
                pendingStartIDs: pendingStartIDs,
                alarmID: alarmID,
                didArmImmediately: false
            ),
            pendingStartIDs
        )
    }

    func testWakeUpCheckCoordinatorConfirmActionQueuesConfirmAndCancelsPendingStart() {
        let alarmID = UUID(uuidString: "CA32F120-5EAA-4DD7-89E3-EA82D64F4284")!
        let unrelatedAlarmID = UUID(uuidString: "A503141D-29F5-4567-A95C-1CD7A6805B2A")!

        let pendingStartIDs: Set<UUID> = [alarmID, unrelatedAlarmID]
        let pendingConfirmIDs: Set<UUID> = [unrelatedAlarmID]

        let nextQueues = WakeUpCheckCoordinator.pendingWakeQueuesAfterConfirmAction(
            alarmID: alarmID,
            pendingStartIDs: pendingStartIDs,
            pendingConfirmIDs: pendingConfirmIDs
        )

        XCTAssertEqual(nextQueues.pendingStartIDs, Set([unrelatedAlarmID]))
        XCTAssertEqual(nextQueues.pendingConfirmIDs, Set([alarmID, unrelatedAlarmID]))
    }

    func testWakeUpCheckCoordinatorArmingFailureResolutionMatchesFallbackPolicy() {
        XCTAssertEqual(
            WakeUpCheckCoordinator.armingFailureResolution(
                isRepeating: false,
                hasActiveSessionAfterAttempt: false
            ),
            .completeNonRepeating
        )
        XCTAssertEqual(
            WakeUpCheckCoordinator.armingFailureResolution(
                isRepeating: true,
                hasActiveSessionAfterAttempt: false
            ),
            .restoreScheduled
        )
        XCTAssertEqual(
            WakeUpCheckCoordinator.armingFailureResolution(
                isRepeating: false,
                hasActiveSessionAfterAttempt: true
            ),
            .keepAwaitingActiveSession
        )
    }

    func testWakeUpCheckCoordinatorCancelsNotificationOnlyWhenArmingReachedNotificationStage() {
        XCTAssertTrue(
            WakeUpCheckCoordinator.shouldCancelNotificationAfterArmingFailure(
                notificationWasScheduled: true
            )
        )
        XCTAssertFalse(
            WakeUpCheckCoordinator.shouldCancelNotificationAfterArmingFailure(
                notificationWasScheduled: false
            )
        )
    }

    func testWakeUpCheckCoordinatorCarriesForwardConfigSnapshotAcrossCycles() {
        let alarmID = UUID(uuidString: "A65F2D6B-EA42-4CF9-B6B3-AC7A6B7E50EF")!
        let previous = WakeUpCheckSessionState(
            alarmID: alarmID,
            cycle: 3,
            checkAt: Date(timeIntervalSince1970: 1_500),
            deadlineAt: Date(timeIntervalSince1970: 1_800),
            notificationID: "previous",
            status: .deadlineFired,
            configSnapshot: WakeUpCheckConfigSnapshot(checkDelayMinutes: 10, responseTimeoutMinutes: 2),
            createdAt: Date(timeIntervalSince1970: 1_200),
            updatedAt: Date(timeIntervalSince1970: 1_900)
        )

        let next = WakeUpCheckCoordinator.nextCycleSession(
            alarmID: alarmID,
            previousSession: previous,
            fallbackSnapshot: WakeUpCheckConfigSnapshot(checkDelayMinutes: 1, responseTimeoutMinutes: 1),
            now: Date(timeIntervalSince1970: 2_000),
            makeNotificationID: { id, cycle in "wakecheck.\(id.uuidString).\(cycle)" }
        )

        XCTAssertEqual(next.cycle, 4)
        XCTAssertEqual(
            next.configSnapshot,
            WakeUpCheckConfigSnapshot(checkDelayMinutes: 10, responseTimeoutMinutes: 2)
        )
        XCTAssertEqual(next.status, .scheduling)
    }

    func testWakeUpCheckSessionStateDecodesLegacySessionAndDerivesSnapshot() throws {
        struct LegacyWakeUpCheckSession: Codable {
            let alarmID: UUID
            let cycle: Int
            let checkAt: Date
            let deadlineAt: Date
            let notificationID: String
            let isAwaitingConfirmation: Bool
            let createdAt: Date
            let updatedAt: Date
        }

        let alarmID = UUID(uuidString: "F8D306E2-DBA7-45A4-9EFC-6516467950A8")!
        let createdAt = Date(timeIntervalSince1970: 10_000)
        let checkAt = createdAt.addingTimeInterval(5 * 60)
        let deadlineAt = checkAt.addingTimeInterval(3 * 60)

        let legacy = LegacyWakeUpCheckSession(
            alarmID: alarmID,
            cycle: 2,
            checkAt: checkAt,
            deadlineAt: deadlineAt,
            notificationID: "legacy.id",
            isAwaitingConfirmation: false,
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(10)
        )

        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(WakeUpCheckSessionState.self, from: data)

        XCTAssertEqual(decoded.alarmID, alarmID)
        XCTAssertEqual(decoded.cycle, 2)
        XCTAssertEqual(decoded.status, .deadlineFired)
        XCTAssertEqual(
            decoded.configSnapshot,
            WakeUpCheckConfigSnapshot(checkDelayMinutes: 5, responseTimeoutMinutes: 3)
        )
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
    private(set) var reconcileBarrierTrace: [String] = []

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

    mutating func seedCanonicalRuntime(triggerDate: Date) {
        runtime.schedule(id: alarm.id, triggerDate: triggerDate)
        lastKnownAlarmState[alarm.id] = .scheduled
        remoteStates[alarm.id] = .scheduled
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

        applyTemporaryScheduleOverrideActivation(
            activation,
            isEnabled: true,
            nextTriggerOverrideDate: triggerDate,
            skipNextUntilDate: nil
        )

        reconcileSchedule(target: .alarm(alarm.id), referenceDate: now)
    }

    mutating func activateDisableNext(now: Date) {
        guard let activation = AlarmSchedulePlanner.activateTemporaryOverride(
            canonicalSchedule: alarm.canonicalScheduleSpec,
            intent: .disableNext,
            now: now,
            manualQueueDepth: manualOverrideQueueDepth,
            calendar: calendar
        ) else {
            XCTFail("expected disable-next activation to succeed")
            return
        }

        applyTemporaryScheduleOverrideActivation(
            activation,
            isEnabled: false,
            nextTriggerOverrideDate: nil,
            skipNextUntilDate: activation.overrideState.skippedCanonicalDate
        )

        reconcileSchedule(target: .alarm(alarm.id), referenceDate: now)
    }

    mutating func resetReconcileBarrierTrace() {
        reconcileBarrierTrace.removeAll()
    }

    mutating func reconcile(trigger: AlarmScheduleReconcileTrigger, referenceDate: Date) {
        reconcileSchedule(
            target: AlarmScheduleReconcileRouting.target(for: trigger),
            referenceDate: referenceDate,
            forceRearm: false
        )
    }

    mutating func reconcileAll(referenceDate: Date) {
        reconcileSchedule(target: .allAlarms, referenceDate: referenceDate, forceRearm: false)
    }

    mutating func reconcileAllForceRearm(referenceDate: Date) {
        reconcileSchedule(target: .allAlarms, referenceDate: referenceDate, forceRearm: true)
    }

    mutating func reconcileForCRUD(alarmID: UUID, referenceDate: Date) {
        reconcileSchedule(target: .alarm(alarmID), referenceDate: referenceDate, forceRearm: true)
    }

    mutating func applyRemoteSnapshot(referenceDate: Date) {
        applyRemoteAlarms(runtime.snapshot(), referenceDate: referenceDate)
    }

    private mutating func reconcileSchedule(
        target: AlarmScheduleReconcileTarget,
        referenceDate: Date,
        forceRearm: Bool = false
    ) {
        switch target {
        case let .alarm(runtimeAlarmID):
            guard let alarmID = owningAlarmID(for: runtimeAlarmID) else {
                return
            }
            reconcileSchedulingForAlarm(alarmID, referenceDate: referenceDate, forceRearm: forceRearm)

        case .allAlarms:
            reconcileSchedulingForAlarm(alarm.id, referenceDate: referenceDate, forceRearm: forceRearm)
        }
    }

    private func owningAlarmID(for runtimeAlarmID: UUID) -> UUID? {
        if alarm.id == runtimeAlarmID {
            return alarm.id
        }

        return alarm.manualScheduleQueue.contains(where: { $0.id == runtimeAlarmID }) ? alarm.id : nil
    }

    private struct HarnessDeterministicReconcilePlan {
        var alarm: HarnessAlarm
        var staleManualRuntimeIDs: Set<UUID>
        var didMutatePersistedState: Bool
    }

    private mutating func reconcileSchedulingForAlarm(_ alarmID: UUID, referenceDate: Date, forceRearm: Bool = false) {
        guard alarm.id == alarmID else {
            return
        }

        reconcileBarrierTrace.append("A")
        let planning = deterministicPlanningBarrier(referenceDate: referenceDate)

        if planning.didMutatePersistedState {
            alarm = planning.alarm
            reconcileBarrierTrace.append("B:commit")
        } else {
            reconcileBarrierTrace.append("B:noop")
        }

        reconcileBarrierTrace.append("C")
        runtimeConvergenceBarrier(
            staleManualRuntimeIDs: planning.staleManualRuntimeIDs,
            referenceDate: referenceDate,
            forceRearm: forceRearm
        )
    }

    private mutating func deterministicPlanningBarrier(referenceDate: Date) -> HarnessDeterministicReconcilePlan {
        var plannedAlarm = alarm
        var staleManualRuntimeIDs: Set<UUID> = []
        var didMutatePersistedState = false

        if let overrideState = plannedAlarm.temporaryScheduleOverride,
           plannedAlarm.isRepeating {
            let desiredDates = AlarmSchedulePlanner.desiredManualTriggerDates(
                canonicalSchedule: plannedAlarm.canonicalScheduleSpec,
                overrideState: overrideState,
                now: referenceDate,
                manualQueueDepth: manualOverrideQueueDepth,
                calendar: calendar
            )

            if desiredDates.isEmpty {
                staleManualRuntimeIDs.formUnion(plannedAlarm.manualScheduleQueue.map(\.id))
                clearTemporaryScheduleOverrideState(
                    on: &plannedAlarm,
                    restoreEnabledState: overrideState.kind == .disableNext ? true : nil,
                    clearManualQueue: true
                )
                didMutatePersistedState = true
            } else {
                var existingByDate: [Date: AlarmManualScheduleEntry] = [:]
                for entry in plannedAlarm.manualScheduleQueue where existingByDate[entry.triggerDate] == nil {
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
                        configReferenceID: plannedAlarm.scheduleConfigReferenceID,
                        role: (overrideState.overrideDate != nil && date == overrideState.overrideDate) ? .overrideTrigger : .canonicalBridge
                    )
                }

                let staleIDs = Set(plannedAlarm.manualScheduleQueue.map(\.id))
                    .subtracting(Set(rebuiltQueue.map(\.id)))
                staleManualRuntimeIDs.formUnion(staleIDs)

                if rebuiltQueue != plannedAlarm.manualScheduleQueue {
                    plannedAlarm.manualScheduleQueue = rebuiltQueue
                    didMutatePersistedState = true
                }
            }
        } else if plannedAlarm.temporaryScheduleOverride != nil {
            staleManualRuntimeIDs.formUnion(plannedAlarm.manualScheduleQueue.map(\.id))
            clearTemporaryScheduleOverrideState(
                on: &plannedAlarm,
                restoreEnabledState: nil,
                clearManualQueue: true
            )
            didMutatePersistedState = true
        }

        if plannedAlarm.temporaryScheduleOverride == nil,
           !plannedAlarm.manualScheduleQueue.isEmpty {
            staleManualRuntimeIDs.formUnion(plannedAlarm.manualScheduleQueue.map(\.id))
            plannedAlarm.manualScheduleQueue.removeAll()
            didMutatePersistedState = true
        }

        return HarnessDeterministicReconcilePlan(
            alarm: plannedAlarm,
            staleManualRuntimeIDs: staleManualRuntimeIDs,
            didMutatePersistedState: didMutatePersistedState
        )
    }

    private mutating func runtimeConvergenceBarrier(
        staleManualRuntimeIDs: Set<UUID>,
        referenceDate: Date,
        forceRearm: Bool = false
    ) {
        cancelRuntimeAlarms(ids: staleManualRuntimeIDs)

        if alarm.temporaryScheduleOverride != nil,
           alarm.isRepeating {
            suppressCanonicalRuntimeWhileOverrideActive(referenceDate: referenceDate)
            scheduleManualRuntimeQueueWithRepair(referenceDate: referenceDate)
            remoteStates[alarm.id] = alarm.manualScheduleQueue.isEmpty ? nil : .scheduled
            return
        }

        if alarm.isEnabled {
            // Mirror production guard: skip re-scheduling when the alarm is
            // already in a healthy runtime state (.scheduled, .countdown,
            // .alerting, .paused).  CRUD edits use forceRearm to bypass
            // the .scheduled guard only.
            if let existing = runtime.byID[alarm.id],
               existing.state == .scheduled || existing.state == .countdown
               || existing.state == .alerting || existing.state == .paused {
                let shouldBypass = forceRearm && existing.state == .scheduled
                if !shouldBypass {
                    lastKnownAlarmState[alarm.id] = existing.state
                    remoteStates[alarm.id] = existing.state
                    return
                }
            }
            // Fall through: re-arm with canonical schedule
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

    private mutating func applyRemoteAlarms(
        _ incoming: [RuntimeAlarmHarness.RuntimeAlarm],
        referenceDate: Date
    ) {
        let remoteByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })

        guard let overrideState = alarm.temporaryScheduleOverride else {
            return
        }

        guard !alarm.manualScheduleQueue.isEmpty else {
            clearTemporaryScheduleOverrideState(
                on: &alarm,
                restoreEnabledState: true,
                clearManualQueue: false
            )
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

        if shouldConsumeOverrideDate,
           !shouldRestoreRecurring {
            _ = consumeTemporaryModifyOverrideDate(on: &alarm)
        }

        if shouldRestoreRecurring {
            // Phase-1 boundary: keep stale manual IDs until reconcile barrier C.
            clearTemporaryScheduleOverrideState(
                on: &alarm,
                restoreEnabledState: true,
                clearManualQueue: false
            )
            remoteStates.removeValue(forKey: alarm.id)
        } else {
            remoteStates[alarm.id] = hasManualAlertingState ? .alerting : .scheduled
        }
    }

    private mutating func applyTemporaryScheduleOverrideActivation(
        _ activation: AlarmTemporaryOverrideActivationPlan,
        isEnabled: Bool,
        nextTriggerOverrideDate: Date?,
        skipNextUntilDate: Date?
    ) {
        alarm.isEnabled = isEnabled
        alarm.nextTriggerOverrideDate = nextTriggerOverrideDate
        alarm.skipNextUntilDate = skipNextUntilDate
        alarm.temporaryScheduleOverride = activation.overrideState
        alarm.manualScheduleQueue = buildManualQueueEntries(
            triggerDates: activation.manualTriggerDates,
            restoreAnchorDate: activation.overrideState.restoreAnchorDate,
            configReferenceID: alarm.scheduleConfigReferenceID,
            overrideDate: activation.overrideState.overrideDate
        )
    }

    private func clearTemporaryScheduleOverrideState(
        on alarm: inout HarnessAlarm,
        restoreEnabledState: Bool?,
        clearManualQueue: Bool
    ) {
        if let restoreEnabledState {
            alarm.isEnabled = restoreEnabledState
        }

        alarm.nextTriggerOverrideDate = nil
        alarm.skipNextUntilDate = nil
        alarm.temporaryScheduleOverride = nil

        if clearManualQueue {
            alarm.manualScheduleQueue.removeAll()
        }
    }

    private func consumeTemporaryModifyOverrideDate(on alarm: inout HarnessAlarm) -> Bool {
        guard var overrideState = alarm.temporaryScheduleOverride,
              overrideState.kind == .modifyNext else {
            return false
        }

        var changed = false

        if alarm.nextTriggerOverrideDate != nil {
            alarm.nextTriggerOverrideDate = nil
            changed = true
        }

        if overrideState.overrideDate != nil {
            overrideState.overrideDate = nil
            alarm.temporaryScheduleOverride = overrideState
            changed = true
        }

        return changed
    }

    private func canonicalSuppressionFallbackDate(referenceDate: Date) -> Date {
        let latestManualDate = alarm.manualScheduleQueue.map(\.triggerDate).max() ?? referenceDate
        let baseline = max(latestManualDate, referenceDate)
        return baseline.addingTimeInterval(60)
    }

    private mutating func suppressCanonicalRuntimeWhileOverrideActive(referenceDate: Date) {
        runtime.stop(id: alarm.id)
        runtime.cancel(id: alarm.id)
        lastKnownAlarmState.removeValue(forKey: alarm.id)

        guard runtime.containsRuntimeAlarm(id: alarm.id) else {
            return
        }

        runtime.schedule(
            id: alarm.id,
            triggerDate: canonicalSuppressionFallbackDate(referenceDate: referenceDate)
        )

        if runtime.containsRuntimeAlarm(id: alarm.id) {
            lastKnownAlarmState[alarm.id] = .scheduled
        }
    }

    private mutating func scheduleManualRuntimeEntry(_ manual: AlarmManualScheduleEntry) {
        // Mirror production guard: skip re-scheduling healthy manual entries
        // (.scheduled, .countdown, .alerting, .paused).
        if let existing = runtime.byID[manual.id],
           existing.state == .scheduled || existing.state == .countdown
           || existing.state == .alerting || existing.state == .paused {
            lastKnownAlarmState[manual.id] = existing.state
            return
        }

        runtime.schedule(id: manual.id, triggerDate: manual.triggerDate)

        if runtime.containsRuntimeAlarm(id: manual.id) {
            lastKnownAlarmState[manual.id] = .scheduled
        }
    }

    private mutating func scheduleManualRuntimeQueueWithRepair(referenceDate: Date) {
        let activeManualEntries = alarm.manualScheduleQueue.filter {
            $0.triggerDate > referenceDate.addingTimeInterval(-1)
        }

        guard !activeManualEntries.isEmpty else {
            return
        }

        for manual in activeManualEntries {
            scheduleManualRuntimeEntry(manual)
        }

        for _ in 0 ..< 2 {
            let missingEntries = activeManualEntries.filter { !runtime.containsRuntimeAlarm(id: $0.id) }
            guard !missingEntries.isEmpty else {
                return
            }

            for manual in missingEntries {
                scheduleManualRuntimeEntry(manual)
            }
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
    private(set) var scheduleCallCount: Int = 0
    private var cancelNoOpIDs: Set<UUID> = []
    private var droppedScheduleAttemptsByTriggerDate: [Date: Int] = [:]

    mutating func addCancelNoOpID(_ id: UUID) {
        cancelNoOpIDs.insert(id)
    }

    mutating func addDroppedScheduleTriggerDate(_ triggerDate: Date) {
        droppedScheduleAttemptsByTriggerDate[triggerDate, default: 0] += 1
    }

    mutating func schedule(id: UUID, triggerDate: Date?) {
        scheduleCallCount += 1

        if let triggerDate,
           let remainingAttempts = droppedScheduleAttemptsByTriggerDate[triggerDate],
           remainingAttempts > 0 {
            if remainingAttempts == 1 {
                droppedScheduleAttemptsByTriggerDate.removeValue(forKey: triggerDate)
            } else {
                droppedScheduleAttemptsByTriggerDate[triggerDate] = remainingAttempts - 1
            }
            return
        }

        byID[id] = RuntimeAlarm(id: id, state: .scheduled, triggerDate: triggerDate)
    }

    mutating func stop(id: UUID) {
        if cancelNoOpIDs.contains(id) {
            return
        }

        guard var current = byID[id] else {
            return
        }

        if current.state == .alerting {
            current.state = .scheduled
            byID[id] = current
        }
    }

    mutating func cancel(id: UUID) {
        if cancelNoOpIDs.contains(id) {
            return
        }

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

    mutating func fireDue(at referenceDate: Date) -> [UUID] {
        let sortedIDs = byID.keys.sorted { $0.uuidString < $1.uuidString }
        var fired: [UUID] = []

        for id in sortedIDs {
            guard var current = byID[id],
                  current.state == .scheduled,
                  let triggerDate = current.triggerDate,
                  triggerDate <= referenceDate else {
                continue
            }

            current.state = .alerting
            byID[id] = current
            fired.append(id)
        }

        return fired
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
