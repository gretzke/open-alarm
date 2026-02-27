import Foundation

public enum AlarmScheduleDesiredMode: Equatable, Sendable {
    case disabled
    case recurring
    case temporarySkip(until: Date)
    case temporaryOneShot(triggerDate: Date)
}

public struct AlarmScheduleDesiredPlan: Equatable, Sendable {
    public var isRepeating: Bool
    public var mode: AlarmScheduleDesiredMode
    public var nextTriggerOverrideDate: Date?

    public init(
        isRepeating: Bool,
        mode: AlarmScheduleDesiredMode,
        nextTriggerOverrideDate: Date? = nil
    ) {
        self.isRepeating = isRepeating
        self.mode = mode
        self.nextTriggerOverrideDate = nextTriggerOverrideDate
    }
}

public enum AlarmScheduleRemoteState: Equatable, Sendable {
    case missing
    case scheduled
    case countdown
    case paused
    case alerting
}

public struct AlarmScheduleActualState: Equatable, Sendable {
    public var previous: AlarmScheduleRemoteState
    public var current: AlarmScheduleRemoteState

    public init(
        previous: AlarmScheduleRemoteState,
        current: AlarmScheduleRemoteState
    ) {
        self.previous = previous
        self.current = current
    }
}

public enum AlarmScheduleOperation: Equatable, Sendable {
    case clearTemporarySkipAndEnableRecurring
    case clearTemporaryOneShot
    case scheduleRecurringRestore
}

public enum WakeUpCheckTimingPolicy {
    public static let debugFiveSecondSentinelMinutes = 0
    public static let defaultCheckDelayMinutes = 5
    public static let defaultResponseTimeoutMinutes = 3
    public static let checkDelayOptionsMinutes: [Int] = [1, 3, 5, 10, 15, 20, 30, 45, 60]
    public static let responseTimeoutOptionsMinutes: [Int] = [1, 2, 3, 5, 10, 20]

    public static func clampCheckDelayMinutes(_ minutes: Int) -> Int {
        if minutes == debugFiveSecondSentinelMinutes {
            return debugFiveSecondSentinelMinutes
        }
        return min(60, max(1, minutes))
    }

    public static func checkDelayInterval(for minutes: Int) -> TimeInterval {
        let normalizedMinutes = clampCheckDelayMinutes(minutes)
        if normalizedMinutes == debugFiveSecondSentinelMinutes {
            return 5
        }
        return TimeInterval(normalizedMinutes * 60)
    }

    public static func normalizeResponseTimeoutMinutes(_ minutes: Int) -> Int {
        if minutes == debugFiveSecondSentinelMinutes {
            return debugFiveSecondSentinelMinutes
        }
        return max(1, minutes)
    }

    public static func responseTimeoutInterval(for minutes: Int) -> TimeInterval {
        let normalizedMinutes = normalizeResponseTimeoutMinutes(minutes)
        if normalizedMinutes == debugFiveSecondSentinelMinutes {
            return 5
        }
        return TimeInterval(normalizedMinutes * 60)
    }
}

/// Pure reconciler retained for existing recurring/one-shot state transitions.
///
/// New unified temporary-override planning is implemented in `AlarmSchedulePlanner`
/// below and consumed by `AlarmStore`.
public enum AlarmScheduleReconciler {
    public static func reconcile(
        desired: AlarmScheduleDesiredPlan,
        actual: AlarmScheduleActualState,
        now: Date
    ) -> [AlarmScheduleOperation] {
        guard desired.isRepeating else {
            return []
        }

        switch desired.mode {
        case .disabled, .recurring:
            return []

        case let .temporarySkip(until):
            guard actual.current == .missing,
                  until <= now else {
                return []
            }

            var operations: [AlarmScheduleOperation] = [
                .clearTemporarySkipAndEnableRecurring
            ]

            if let overrideDate = desired.nextTriggerOverrideDate,
               overrideDate <= until {
                operations.append(.clearTemporaryOneShot)
            }

            operations.append(.scheduleRecurringRestore)
            return operations

        case let .temporaryOneShot(triggerDate):
            let completedFromFireTransition =
                actual.previous == .alerting && actual.current != .alerting
            let completedWhileColdStart =
                actual.current == .missing && triggerDate <= now

            guard completedFromFireTransition || completedWhileColdStart else {
                return []
            }

            return [
                .clearTemporaryOneShot,
                .scheduleRecurringRestore
            ]
        }
    }

    public static func shouldScheduleManualRecurringRestore(
        reconciliationOperations: [AlarmScheduleOperation],
        hadSnoozes: Bool,
        wakeUpCheckEnabled: Bool,
        wakeUpCheckStarted: Bool
    ) -> Bool {
        let reconciliationRequestedRecurringRestore = reconciliationOperations.contains(.scheduleRecurringRestore)
        let snoozePathNeedsRecurringRestore = hadSnoozes && !reconciliationRequestedRecurringRestore

        if wakeUpCheckEnabled {
            guard !wakeUpCheckStarted else {
                return false
            }

            return reconciliationRequestedRecurringRestore || snoozePathNeedsRecurringRestore
        }

        return snoozePathNeedsRecurringRestore
    }
}

// MARK: - Unified temporary override planner (disable-next / modify-next)

/// Canonical recurring schedule definition used by the scheduling state machine.
///
/// This shape intentionally excludes snooze/wake-check/ringtone config so schedule
/// reconciliation is deterministic and config-independent.
public struct AlarmCanonicalScheduleSpec: Equatable, Sendable {
    public var weekdayNumbers: [Int]
    public var hour: Int
    public var minute: Int
    public var isEnabled: Bool

    public init(
        weekdayNumbers: [Int],
        hour: Int,
        minute: Int,
        isEnabled: Bool
    ) {
        self.weekdayNumbers = Array(Set(weekdayNumbers.filter { (1 ... 7).contains($0) })).sorted()
        self.hour = hour
        self.minute = minute
        self.isEnabled = isEnabled
    }

    public var isRepeating: Bool {
        !weekdayNumbers.isEmpty
    }
}

/// Mutable schedule actions users can take for a repeating alarm.
public enum AlarmTemporaryOverrideIntent: Equatable, Sendable {
    case disableNext
    case modifyNext(triggerDate: Date)
}

/// Persisted override mode while recurring scheduling is temporarily replaced by
/// manual one-shot bridge alarms.
public enum AlarmTemporaryScheduleOverrideKind: String, Codable, Equatable, Sendable {
    case disableNext
    case modifyNext
}

/// Persisted override state that drives deterministic restore behavior.
///
/// Invariant:
/// - `restoreAnchorDate` is the earliest manual fire date that may restore recurring.
/// - A fired manual alarm restores recurring iff `firedAt >= restoreAnchorDate`.
///
/// For modify-next-earlier, `overrideDate < restoreAnchorDate`, so the first ring
/// does not restore and the second (usual-time anchor) does.
public struct AlarmTemporaryScheduleOverride: Codable, Equatable, Sendable {
    public var kind: AlarmTemporaryScheduleOverrideKind
    public var overrideDate: Date?
    public var restoreAnchorDate: Date
    public var skippedCanonicalDate: Date?
    public var activatedAt: Date

    public init(
        kind: AlarmTemporaryScheduleOverrideKind,
        overrideDate: Date?,
        restoreAnchorDate: Date,
        skippedCanonicalDate: Date?,
        activatedAt: Date
    ) {
        self.kind = kind
        self.overrideDate = overrideDate
        self.restoreAnchorDate = restoreAnchorDate
        self.skippedCanonicalDate = skippedCanonicalDate
        self.activatedAt = activatedAt
    }
}

public enum AlarmManualScheduleRole: String, Codable, Equatable, Sendable {
    /// Explicit modified next alarm chosen by user.
    case overrideTrigger
    /// Canonical repeating alarm used as restore bridge/fallback.
    case canonicalBridge
}

/// Concrete one-shot alarm scheduled while a temporary override is active.
///
/// `configReferenceID` is stable across queue rebuilds and points to the alarm
/// configuration identity (not runtime AlarmKit alarm ID).
public struct AlarmManualScheduleEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var triggerDate: Date
    public var restoreAnchorDate: Date
    public var configReferenceID: UUID
    public var role: AlarmManualScheduleRole

    public init(
        id: UUID,
        triggerDate: Date,
        restoreAnchorDate: Date,
        configReferenceID: UUID,
        role: AlarmManualScheduleRole
    ) {
        self.id = id
        self.triggerDate = triggerDate
        self.restoreAnchorDate = restoreAnchorDate
        self.configReferenceID = configReferenceID
        self.role = role
    }
}

public struct AlarmTemporaryOverrideActivationPlan: Equatable, Sendable {
    public var overrideState: AlarmTemporaryScheduleOverride
    public var manualTriggerDates: [Date]

    public init(
        overrideState: AlarmTemporaryScheduleOverride,
        manualTriggerDates: [Date]
    ) {
        self.overrideState = overrideState
        self.manualTriggerDates = manualTriggerDates
    }
}

public struct AlarmCanonicalScheduleSignature: Equatable, Sendable {
    public var weekdayNumbers: [Int]
    public var hour: Int
    public var minute: Int
    public var isEnabled: Bool

    public init(spec: AlarmCanonicalScheduleSpec) {
        weekdayNumbers = spec.weekdayNumbers
        hour = spec.hour
        minute = spec.minute
        isEnabled = spec.isEnabled
    }
}

/// Deterministic planner/reconciler for temporary override scheduling.
public enum AlarmSchedulePlanner {
    public static let defaultManualQueueDepth = 5

    /// Canonical schedule mutations must clear temporary override state.
    ///
    /// This enforces "schedule changes win" and prevents stale override bridges
    /// from surviving day/time/full-toggle edits.
    public static func shouldClearTemporaryOverride(
        previous: AlarmCanonicalScheduleSignature,
        next: AlarmCanonicalScheduleSignature
    ) -> Bool {
        previous != next
    }

    /// Creates temporary override state and initial manual one-shot queue.
    ///
    /// The resulting queue length is `manualQueueDepth` and is safe to rebuild
    /// repeatedly from app-open / callback reconciliation opportunities.
    public static func activateTemporaryOverride(
        canonicalSchedule: AlarmCanonicalScheduleSpec,
        intent: AlarmTemporaryOverrideIntent,
        now: Date,
        manualQueueDepth: Int = defaultManualQueueDepth,
        calendar: Calendar = .autoupdatingCurrent
    ) -> AlarmTemporaryOverrideActivationPlan? {
        guard canonicalSchedule.isEnabled,
              canonicalSchedule.isRepeating,
              manualQueueDepth > 0,
              let nextCanonical = nextCanonicalOccurrence(
                  after: now,
                  schedule: canonicalSchedule,
                  calendar: calendar
              ) else {
            return nil
        }

        let overrideState: AlarmTemporaryScheduleOverride

        switch intent {
        case .disableNext:
            guard let restoreAnchor = nextCanonicalOccurrence(
                after: nextCanonical,
                schedule: canonicalSchedule,
                calendar: calendar
            ) else {
                return nil
            }

            overrideState = AlarmTemporaryScheduleOverride(
                kind: .disableNext,
                overrideDate: nil,
                restoreAnchorDate: restoreAnchor,
                skippedCanonicalDate: nextCanonical,
                activatedAt: now
            )

        case let .modifyNext(triggerDate):
            let normalizedTriggerDate = max(triggerDate, now.addingTimeInterval(1))

            overrideState = AlarmTemporaryScheduleOverride(
                kind: .modifyNext,
                overrideDate: normalizedTriggerDate,
                restoreAnchorDate: nextCanonical,
                skippedCanonicalDate: nil,
                activatedAt: now
            )
        }

        return AlarmTemporaryOverrideActivationPlan(
            overrideState: overrideState,
            manualTriggerDates: desiredManualTriggerDates(
                canonicalSchedule: canonicalSchedule,
                overrideState: overrideState,
                now: now,
                manualQueueDepth: manualQueueDepth,
                calendar: calendar
            )
        )
    }

    /// Rebuilds the desired manual one-shot queue for an active override.
    ///
    /// Why rebuilding is safe:
    /// - It is pure and deterministic from persisted override + canonical schedule.
    /// - It can run on every app-open/callback without dependence on wake-check.
    /// - It always emits at most `manualQueueDepth` future dates.
    public static func desiredManualTriggerDates(
        canonicalSchedule: AlarmCanonicalScheduleSpec,
        overrideState: AlarmTemporaryScheduleOverride,
        now: Date,
        manualQueueDepth: Int = defaultManualQueueDepth,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [Date] {
        guard canonicalSchedule.isEnabled,
              canonicalSchedule.isRepeating,
              manualQueueDepth > 0 else {
            return []
        }

        switch overrideState.kind {
        case .disableNext:
            // Disable-next skips the first canonical occurrence and restores on
            // the next canonical anchor (or the next available future bridge if
            // the anchor was already missed while offline).
            if now < overrideState.restoreAnchorDate {
                let tail = canonicalOccurrences(
                    after: overrideState.restoreAnchorDate,
                    schedule: canonicalSchedule,
                    count: max(0, manualQueueDepth - 1),
                    calendar: calendar
                )
                return normalizeManualDates(
                    [overrideState.restoreAnchorDate] + tail,
                    depth: manualQueueDepth
                )
            }

            return normalizeManualDates(
                canonicalOccurrences(
                    after: now,
                    schedule: canonicalSchedule,
                    count: manualQueueDepth,
                    calendar: calendar
                ),
                depth: manualQueueDepth
            )

        case .modifyNext:
            let overrideDate = overrideState.overrideDate ?? overrideState.restoreAnchorDate

            var candidates: [Date] = []

            if overrideDate > now {
                candidates.append(overrideDate)
            }

            if overrideDate < overrideState.restoreAnchorDate,
               overrideState.restoreAnchorDate > now {
                // Earlier-than-usual path: keep explicit usual-time anchor so the
                // first ring does not restore and the second one does.
                candidates.append(overrideState.restoreAnchorDate)
            }

            // After the explicit override/anchor points, canonical bridges keep
            // restore opportunities alive if callbacks were missed.
            let bridgeSeed = max(now, max(overrideState.restoreAnchorDate, overrideDate))
            let bridges = canonicalOccurrences(
                after: bridgeSeed,
                schedule: canonicalSchedule,
                count: manualQueueDepth,
                calendar: calendar
            )

            candidates.append(contentsOf: bridges)
            return normalizeManualDates(candidates, depth: manualQueueDepth)
        }
    }

    /// Restore criterion used by callbacks and cold-start recovery.
    ///
    /// This single inequality unifies all flows:
    /// - disable-next: first bridge date equals restore anchor
    /// - modify earlier: first manual < anchor (no restore), second >= anchor (restore)
    /// - modify later: override date is >= anchor (restore immediately)
    public static func shouldRestoreRecurringSchedule(
        afterManualAlarmFiredAt firedAt: Date,
        overrideState: AlarmTemporaryScheduleOverride
    ) -> Bool {
        firedAt >= overrideState.restoreAnchorDate
    }

    /// Returns the next canonical occurrence strictly after `referenceDate`.
    public static func nextCanonicalOccurrence(
        after referenceDate: Date,
        schedule: AlarmCanonicalScheduleSpec,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        guard schedule.isEnabled,
              schedule.isRepeating else {
            return nil
        }

        let searchStart = referenceDate.addingTimeInterval(1)

        let candidates = schedule.weekdayNumbers.compactMap { weekday -> Date? in
            var components = DateComponents()
            components.weekday = weekday
            components.hour = schedule.hour
            components.minute = schedule.minute
            components.second = 0

            return calendar.nextDate(
                after: searchStart,
                matching: components,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            )
        }

        return candidates.min()
    }

    /// Returns `count` canonical occurrences strictly after `referenceDate`.
    public static func canonicalOccurrences(
        after referenceDate: Date,
        schedule: AlarmCanonicalScheduleSpec,
        count: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [Date] {
        guard count > 0,
              schedule.isEnabled,
              schedule.isRepeating else {
            return []
        }

        var output: [Date] = []
        var cursor = referenceDate

        while output.count < count {
            guard let next = nextCanonicalOccurrence(
                after: cursor,
                schedule: schedule,
                calendar: calendar
            ) else {
                break
            }

            output.append(next)
            cursor = next
        }

        return output
    }

    private static func normalizeManualDates(
        _ dates: [Date],
        depth: Int
    ) -> [Date] {
        guard depth > 0 else {
            return []
        }

        var normalized: [Date] = []
        for candidate in dates.sorted() {
            if normalized.contains(candidate) {
                continue
            }
            normalized.append(candidate)
            if normalized.count == depth {
                break
            }
        }

        return normalized
    }
}
