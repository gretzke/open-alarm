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
            print("✅ Deterministic reconciler checks passed (4/4)")
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
    }
}
