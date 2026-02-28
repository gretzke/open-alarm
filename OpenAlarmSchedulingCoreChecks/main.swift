import Foundation
import OpenAlarmSchedulingCore

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
struct AlarmScheduleReconcilerDeterministicChecks {
    static func main() {
        do {
            try runChecks()
            print("✅ Deterministic scheduling checks passed (22/22)")
        } catch {
            if let failure = error as? CheckFailure {
                fputs("❌ \(failure.message)\n", stderr)
            } else {
                fputs("❌ Unexpected error: \(error)\n", stderr)
            }
            exit(1)
        }
    }

    static func runChecks() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)

        // 1) skip-next -> next valid occurrence -> recurring restore
        do {
            let skipUntil = now.addingTimeInterval(-1)
            let desired = AlarmScheduleDesiredPlan(
                isRepeating: true,
                mode: .temporarySkip(until: skipUntil)
            )
            let actual = AlarmScheduleActualState(previous: .missing, current: .missing)

            let operations = AlarmScheduleReconciler.reconcile(
                desired: desired,
                actual: actual,
                now: now
            )

            try expectEqual(
                operations,
                [.clearTemporarySkipAndEnableRecurring, .scheduleRecurringRestore],
                "skip-next scenario should restore recurring schedule"
            )
        }

        // 2) modify-next-once -> recurring restore
        do {
            let oneShotTrigger = now.addingTimeInterval(-30)
            let desired = AlarmScheduleDesiredPlan(
                isRepeating: true,
                mode: .temporaryOneShot(triggerDate: oneShotTrigger),
                nextTriggerOverrideDate: oneShotTrigger
            )
            let actual = AlarmScheduleActualState(previous: .alerting, current: .missing)

            let operations = AlarmScheduleReconciler.reconcile(
                desired: desired,
                actual: actual,
                now: now
            )

            try expectEqual(
                operations,
                [.clearTemporaryOneShot, .scheduleRecurringRestore],
                "modify-next-once scenario should restore recurring schedule"
            )
        }

        // 3) duplicate fire callback idempotency
        do {
            let oneShotTrigger = now.addingTimeInterval(-60)
            let firstDesired = AlarmScheduleDesiredPlan(
                isRepeating: true,
                mode: .temporaryOneShot(triggerDate: oneShotTrigger),
                nextTriggerOverrideDate: oneShotTrigger
            )
            let firstActual = AlarmScheduleActualState(previous: .alerting, current: .missing)

            let firstOps = AlarmScheduleReconciler.reconcile(
                desired: firstDesired,
                actual: firstActual,
                now: now
            )

            try expectEqual(
                firstOps,
                [.clearTemporaryOneShot, .scheduleRecurringRestore],
                "first fire callback should consume one-shot and restore recurring"
            )

            let duplicateDesired = AlarmScheduleDesiredPlan(
                isRepeating: true,
                mode: .recurring,
                nextTriggerOverrideDate: nil
            )
            let duplicateActual = AlarmScheduleActualState(previous: .missing, current: .missing)

            let duplicateOps = AlarmScheduleReconciler.reconcile(
                desired: duplicateDesired,
                actual: duplicateActual,
                now: now
            )

            try expectTrue(
                duplicateOps.isEmpty,
                "duplicate callback should produce no additional operations"
            )
        }

        // 4) cold-start recovery from temporary/one-shot mode
        do {
            let oneShotTrigger = now.addingTimeInterval(-120)
            let desired = AlarmScheduleDesiredPlan(
                isRepeating: true,
                mode: .temporaryOneShot(triggerDate: oneShotTrigger),
                nextTriggerOverrideDate: oneShotTrigger
            )
            let actual = AlarmScheduleActualState(previous: .missing, current: .missing)

            let operations = AlarmScheduleReconciler.reconcile(
                desired: desired,
                actual: actual,
                now: now
            )

            try expectEqual(
                operations,
                [.clearTemporaryOneShot, .scheduleRecurringRestore],
                "cold-start recovery should restore recurring schedule from persisted one-shot mode"
            )
        }

        // 5) stop-intent hook routes to single-alarm reconcile
        do {
            let alarmID = UUID(uuidString: "DCE8CB2E-01D8-4548-B03A-2A12F3A16DB1")!
            try expectEqual(
                AlarmScheduleReconcileRouting.target(for: .stopIntent(alarmID)),
                .alarm(alarmID),
                "stop intent should route to alarm-scoped reconcile"
            )
        }

        // 6) snooze-intent hook routes to single-alarm reconcile
        do {
            let alarmID = UUID(uuidString: "FB0C589E-8D72-45B3-B16F-25FC774E5FF9")!
            try expectEqual(
                AlarmScheduleReconcileRouting.target(for: .snoozeIntent(alarmID)),
                .alarm(alarmID),
                "snooze intent should route to alarm-scoped reconcile"
            )
        }

        // 7) app-launch hook routes to all-alarms reconcile
        do {
            try expectEqual(
                AlarmScheduleReconcileRouting.target(for: .appLaunch),
                .allAlarms,
                "app-launch reconciliation should route to all alarms"
            )
        }

        // 8) reconcile hook routing is idempotent
        do {
            let alarmID = UUID(uuidString: "2D78DAD2-3D64-4B9E-A2A9-DCA6A743DF9F")!
            let stopFirst = AlarmScheduleReconcileRouting.target(for: .stopIntent(alarmID))
            let stopSecond = AlarmScheduleReconcileRouting.target(for: .stopIntent(alarmID))
            let snoozeFirst = AlarmScheduleReconcileRouting.target(for: .snoozeIntent(alarmID))
            let snoozeSecond = AlarmScheduleReconcileRouting.target(for: .snoozeIntent(alarmID))
            let launchFirst = AlarmScheduleReconcileRouting.target(for: .appLaunch)
            let launchSecond = AlarmScheduleReconcileRouting.target(for: .appLaunch)

            try expectEqual(stopFirst, stopSecond, "stop hook should be deterministic")
            try expectEqual(snoozeFirst, snoozeSecond, "snooze hook should be deterministic")
            try expectEqual(stopFirst, snoozeFirst, "stop and snooze should share the same single-alarm reconcile route")
            try expectEqual(launchFirst, launchSecond, "app-launch hook should be deterministic")
        }

        // 9) disable-next activation builds N=5 manual queue anchored to second canonical occurrence
        do {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!

            let now = DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 2,
                day: 28,
                hour: 6,
                minute: 0,
                second: 0
            ).date!

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

            try expectTrue(activation != nil, "disable-next activation should succeed")
            try expectEqual(activation?.overrideState.kind, .disableNext, "override mode should be disable-next")
            try expectEqual(activation?.manualTriggerDates.count, 5, "disable-next should enqueue 5 manual bridge alarms")

            let expectedAnchor = DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 3,
                day: 1,
                hour: 7,
                minute: 0,
                second: 0
            ).date!
            try expectEqual(
                activation?.overrideState.restoreAnchorDate,
                expectedAnchor,
                "disable-next restore anchor should be second canonical occurrence"
            )
        }

        // 10) Mon/Fri modify-next-earlier applies once, consumes override, and skips same-day canonical
        do {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!

            let now = DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 3,
                day: 1,
                hour: 12,
                minute: 0,
                second: 0
            ).date! // Sunday
            let mondayOverride = DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 3,
                day: 2,
                hour: 8,
                minute: 0,
                second: 0
            ).date!
            let mondayCanonical = DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 3,
                day: 2,
                hour: 9,
                minute: 0,
                second: 0
            ).date!
            let fridayCanonical = DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 3,
                day: 6,
                hour: 9,
                minute: 0,
                second: 0
            ).date!

            let schedule = AlarmCanonicalScheduleSpec(
                weekdayNumbers: [2, 6],
                hour: 9,
                minute: 0,
                isEnabled: true
            )

            let activation = AlarmSchedulePlanner.activateTemporaryOverride(
                canonicalSchedule: schedule,
                intent: .modifyNext(triggerDate: mondayOverride),
                now: now,
                manualQueueDepth: 5,
                calendar: calendar
            )

            try expectTrue(activation != nil, "modify-next Mon/Fri activation should succeed")
            try expectEqual(activation?.manualTriggerDates.first, mondayOverride, "first trigger should be override day/time")
            try expectEqual(activation?.manualTriggerDates.dropFirst().first, fridayCanonical, "second trigger should skip Monday 09:00 and bridge to Friday")
            try expectTrue(
                !(activation?.manualTriggerDates.contains(mondayCanonical) ?? true),
                "queue must not include same-day canonical slot after earlier override"
            )

            try expectTrue(
                AlarmSchedulePlanner.shouldConsumeOverrideDate(
                    afterManualAlarmFiredAt: mondayOverride,
                    overrideState: activation!.overrideState
                ),
                "override date should be consumed on first eligible manual ring"
            )
            try expectTrue(
                !AlarmSchedulePlanner.shouldRestoreRecurringSchedule(
                    afterManualAlarmFiredAt: mondayOverride,
                    overrideState: activation!.overrideState
                ),
                "first eligible override ring should not restore recurring before anchor"
            )

            var consumedState = activation!.overrideState
            consumedState.overrideDate = nil

            let mondayAfterOverride = DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 3,
                day: 2,
                hour: 8,
                minute: 30,
                second: 0
            ).date!

            let rebuilt = AlarmSchedulePlanner.desiredManualTriggerDates(
                canonicalSchedule: schedule,
                overrideState: consumedState,
                now: mondayAfterOverride,
                manualQueueDepth: 5,
                calendar: calendar
            )

            try expectEqual(rebuilt.first, fridayCanonical, "reconcile after consume should not reintroduce Monday 09:00")
            try expectTrue(
                !rebuilt.contains(mondayCanonical),
                "reconcile should not revive stale same-day canonical trigger"
            )
        }

        // 11) modify-next-later restores at overridden ring
        do {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!

            let now = DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 2,
                day: 28,
                hour: 6,
                minute: 0,
                second: 0
            ).date!
            let overrideDate = DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 2,
                day: 28,
                hour: 9,
                minute: 0,
                second: 0
            ).date!

            let schedule = AlarmCanonicalScheduleSpec(
                weekdayNumbers: [1, 2, 3, 4, 5, 6, 7],
                hour: 8,
                minute: 0,
                isEnabled: true
            )

            let activation = AlarmSchedulePlanner.activateTemporaryOverride(
                canonicalSchedule: schedule,
                intent: .modifyNext(triggerDate: overrideDate),
                now: now,
                manualQueueDepth: 5,
                calendar: calendar
            )

            try expectTrue(activation != nil, "modify-next-later activation should succeed")
            try expectTrue(
                AlarmSchedulePlanner.shouldRestoreRecurringSchedule(
                    afterManualAlarmFiredAt: overrideDate,
                    overrideState: activation!.overrideState
                ),
                "later override ring should restore recurring"
            )
        }

        // 12) schedule signature changes clear temporary override state
        do {
            let previous = AlarmCanonicalScheduleSignature(
                spec: AlarmCanonicalScheduleSpec(
                    weekdayNumbers: [2, 4, 6],
                    hour: 8,
                    minute: 15,
                    isEnabled: true
                )
            )

            let same = AlarmCanonicalScheduleSignature(
                spec: AlarmCanonicalScheduleSpec(
                    weekdayNumbers: [2, 4, 6],
                    hour: 8,
                    minute: 15,
                    isEnabled: true
                )
            )
            let changed = AlarmCanonicalScheduleSignature(
                spec: AlarmCanonicalScheduleSpec(
                    weekdayNumbers: [2, 4],
                    hour: 8,
                    minute: 45,
                    isEnabled: true
                )
            )

            try expectTrue(
                !AlarmSchedulePlanner.shouldClearTemporaryOverride(previous: previous, next: same),
                "identical schedule signatures should not clear override"
            )
            try expectTrue(
                AlarmSchedulePlanner.shouldClearTemporaryOverride(previous: previous, next: changed),
                "schedule edits should clear temporary override"
            )
        }

        // 13) wake-check delay options include required user-facing choices
        do {
            try expectEqual(
                WakeUpCheckTimingPolicy.checkDelayOptionsMinutes,
                [1, 3, 5, 10, 15, 20, 30, 45, 60],
                "wake-check delay options should match UX requirements"
            )
        }

        // 14) wake-check delay debug sentinel uses 5-second delay
        do {
            try expectEqual(
                WakeUpCheckTimingPolicy.checkDelayInterval(
                    for: WakeUpCheckTimingPolicy.debugFiveSecondSentinelMinutes
                ),
                5,
                "wake-check debug delay should be 5 seconds"
            )
        }

        // 15) wake-check normal delay values stay minute-based
        do {
            try expectEqual(
                WakeUpCheckTimingPolicy.checkDelayInterval(for: 5),
                300,
                "wake-check 5-minute delay should map to 300 seconds"
            )
        }

        // 16) wake-check delay clamping preserves debug sentinel and clamps invalid values
        do {
            try expectEqual(
                WakeUpCheckTimingPolicy.clampCheckDelayMinutes(
                    WakeUpCheckTimingPolicy.debugFiveSecondSentinelMinutes
                ),
                0,
                "debug sentinel should remain 0"
            )
            try expectEqual(
                WakeUpCheckTimingPolicy.clampCheckDelayMinutes(-2),
                1,
                "invalid delay values should clamp to 1 minute"
            )
            try expectEqual(
                WakeUpCheckTimingPolicy.clampCheckDelayMinutes(120),
                60,
                "delay values above range should clamp to 60 minutes"
            )
        }

        // 17) wake-check timeout options include required user-facing choices
        do {
            try expectEqual(
                WakeUpCheckTimingPolicy.responseTimeoutOptionsMinutes,
                [1, 2, 3, 5, 10, 20],
                "wake-check response timeout options should match UX requirements"
            )
        }

        // 18) wake-check timeout debug sentinel uses 5-second timeout
        do {
            try expectEqual(
                WakeUpCheckTimingPolicy.responseTimeoutInterval(
                    for: WakeUpCheckTimingPolicy.debugFiveSecondSentinelMinutes
                ),
                5,
                "wake-check debug timeout should be 5 seconds"
            )
        }

        // 19) wake-check normal timeout values stay minute-based
        do {
            try expectEqual(
                WakeUpCheckTimingPolicy.responseTimeoutInterval(for: 3),
                180,
                "wake-check 3-minute timeout should map to 180 seconds"
            )
        }

        // 20) wake-check timeout normalization preserves debug sentinel and clamps invalid values
        do {
            try expectEqual(
                WakeUpCheckTimingPolicy.normalizeResponseTimeoutMinutes(
                    WakeUpCheckTimingPolicy.debugFiveSecondSentinelMinutes
                ),
                0,
                "debug sentinel should remain 0"
            )
            try expectEqual(
                WakeUpCheckTimingPolicy.normalizeResponseTimeoutMinutes(-2),
                1,
                "invalid timeout values should clamp to 1 minute"
            )
        }

        // 21) disable-next vs modify-next are mutually exclusive modes
        do {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let now = DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 2,
                day: 28,
                hour: 6,
                minute: 0,
                second: 0
            ).date!
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

            try expectEqual(disable?.overrideState.kind, .disableNext, "disable-next intent should set disable-next mode")
            try expectEqual(modify?.overrideState.kind, .modifyNext, "modify intent should set modify-next mode")
        }

        // 22) fallback queue rebuild after missed anchor still emits future bridges
        do {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!

            let now = DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 2,
                day: 28,
                hour: 6,
                minute: 0,
                second: 0
            ).date!
            let afterMissedAnchor = DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 3,
                day: 1,
                hour: 8,
                minute: 0,
                second: 0
            ).date!

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

            try expectTrue(activation != nil, "disable-next activation should succeed")

            let rebuilt = AlarmSchedulePlanner.desiredManualTriggerDates(
                canonicalSchedule: schedule,
                overrideState: activation!.overrideState,
                now: afterMissedAnchor,
                manualQueueDepth: 5,
                calendar: calendar
            )

            try expectEqual(rebuilt.count, 5, "fallback queue should keep depth=5")
            try expectTrue(
                rebuilt.allSatisfy { $0 > afterMissedAnchor },
                "fallback queue after missed anchor should contain only future bridges"
            )
        }
    }
}
