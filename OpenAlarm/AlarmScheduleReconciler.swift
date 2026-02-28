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

public enum AlarmScheduleReconcileTarget: Equatable, Sendable {
    case alarm(UUID)
    case allAlarms
}

public enum AlarmScheduleReconcileTrigger: Equatable, Sendable {
    case stopIntent(UUID)
    case snoozeIntent(UUID)
    case appLaunch
}

public enum AlarmScheduleReconcileRouting {
    public static func target(for trigger: AlarmScheduleReconcileTrigger) -> AlarmScheduleReconcileTarget {
        switch trigger {
        case let .stopIntent(alarmID), let .snoozeIntent(alarmID):
            return .alarm(alarmID)
        case .appLaunch:
            return .allAlarms
        }
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

public struct WakeUpCheckConfigSnapshot: Codable, Equatable, Sendable {
    public var checkDelayMinutes: Int
    public var responseTimeoutMinutes: Int

    public init(checkDelayMinutes: Int, responseTimeoutMinutes: Int) {
        self.checkDelayMinutes = WakeUpCheckTimingPolicy.clampCheckDelayMinutes(checkDelayMinutes)
        self.responseTimeoutMinutes = WakeUpCheckTimingPolicy.normalizeResponseTimeoutMinutes(responseTimeoutMinutes)
    }
}

public enum WakeUpCheckSessionStatus: String, Codable, Equatable, Sendable {
    /// Durable transition written before side-effects (notification + runtime alarm).
    case scheduling

    /// Notification + runtime alarm are intended to be armed for this cycle.
    case awaitingConfirmation

    /// Deadline alarm has reached alerting state at least once in this cycle.
    case deadlineFired
}

public struct WakeUpCheckSessionState: Codable, Equatable, Sendable {
    public var alarmID: UUID
    public var cycle: Int
    public var checkAt: Date
    public var deadlineAt: Date
    public var notificationID: String
    public var status: WakeUpCheckSessionStatus
    public var configSnapshot: WakeUpCheckConfigSnapshot
    public var createdAt: Date
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case alarmID
        case cycle
        case checkAt
        case deadlineAt
        case notificationID
        case status
        case configSnapshot
        case createdAt
        case updatedAt
        case legacyIsAwaitingConfirmation = "isAwaitingConfirmation"
    }

    public init(
        alarmID: UUID,
        cycle: Int,
        checkAt: Date,
        deadlineAt: Date,
        notificationID: String,
        status: WakeUpCheckSessionStatus,
        configSnapshot: WakeUpCheckConfigSnapshot,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.alarmID = alarmID
        self.cycle = cycle
        self.checkAt = checkAt
        self.deadlineAt = deadlineAt
        self.notificationID = notificationID
        self.status = status
        self.configSnapshot = configSnapshot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        alarmID = try container.decode(UUID.self, forKey: .alarmID)
        cycle = try container.decodeIfPresent(Int.self, forKey: .cycle) ?? 1
        checkAt = try container.decode(Date.self, forKey: .checkAt)
        deadlineAt = try container.decode(Date.self, forKey: .deadlineAt)
        notificationID = try container.decodeIfPresent(String.self, forKey: .notificationID) ?? ""

        if let decodedStatus = try container.decodeIfPresent(WakeUpCheckSessionStatus.self, forKey: .status) {
            status = decodedStatus
        } else if let legacyAwaiting = try container.decodeIfPresent(Bool.self, forKey: .legacyIsAwaitingConfirmation) {
            status = legacyAwaiting ? .awaitingConfirmation : .deadlineFired
        } else {
            status = .awaitingConfirmation
        }

        let decodedCreatedAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        let decodedUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? decodedCreatedAt

        if let decodedSnapshot = try container.decodeIfPresent(WakeUpCheckConfigSnapshot.self, forKey: .configSnapshot) {
            configSnapshot = decodedSnapshot
        } else {
            // Legacy migration: previous session shape did not persist an explicit
            // wake-check config snapshot. Derive best-effort values from persisted
            // check/deadline timing deltas so repeated cycles remain stable.
            let checkDelayRawMinutes = Int(round(checkAt.timeIntervalSince(decodedCreatedAt) / 60.0))
            let timeoutRawMinutes = Int(round(deadlineAt.timeIntervalSince(checkAt) / 60.0))
            configSnapshot = WakeUpCheckConfigSnapshot(
                checkDelayMinutes: checkDelayRawMinutes,
                responseTimeoutMinutes: timeoutRawMinutes
            )
        }

        createdAt = decodedCreatedAt
        updatedAt = decodedUpdatedAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(alarmID, forKey: .alarmID)
        try container.encode(cycle, forKey: .cycle)
        try container.encode(checkAt, forKey: .checkAt)
        try container.encode(deadlineAt, forKey: .deadlineAt)
        try container.encode(notificationID, forKey: .notificationID)
        try container.encode(status, forKey: .status)
        try container.encode(configSnapshot, forKey: .configSnapshot)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

public enum WakeUpCheckStateMachine {
    public static func nextCycle(
        alarmID: UUID,
        previousSession: WakeUpCheckSessionState?,
        configSnapshot: WakeUpCheckConfigSnapshot,
        now: Date,
        makeNotificationID: (UUID, Int) -> String
    ) -> WakeUpCheckSessionState {
        let nextCycle = (previousSession?.cycle ?? 0) + 1
        let checkAt = now.addingTimeInterval(
            WakeUpCheckTimingPolicy.checkDelayInterval(for: configSnapshot.checkDelayMinutes)
        )
        let deadlineAt = checkAt.addingTimeInterval(
            WakeUpCheckTimingPolicy.responseTimeoutInterval(for: configSnapshot.responseTimeoutMinutes)
        )

        return WakeUpCheckSessionState(
            alarmID: alarmID,
            cycle: nextCycle,
            checkAt: checkAt,
            deadlineAt: deadlineAt,
            notificationID: makeNotificationID(alarmID, nextCycle),
            status: .scheduling,
            configSnapshot: configSnapshot,
            createdAt: now,
            updatedAt: now
        )
    }

    public static func markAwaitingConfirmation(
        _ session: WakeUpCheckSessionState,
        now: Date
    ) -> WakeUpCheckSessionState {
        var next = session
        next.status = .awaitingConfirmation
        next.updatedAt = now
        return next
    }

    public static func markDeadlineFired(
        _ session: WakeUpCheckSessionState,
        now: Date
    ) -> WakeUpCheckSessionState {
        var next = session
        next.status = .deadlineFired
        next.updatedAt = now
        return next
    }
}

/// Coordinator model layered on top of `WakeUpCheckStateMachine`.
///
/// `WakeUpCheckStateMachine` stays focused on pure cycle/status transitions,
/// while this coordinator owns policy decisions about when the pipeline should
/// run and how cycle config snapshots should be carried across repeated cycles.
public enum WakeUpCheckCoordinator {
    /// Wake-check pipeline entry from StopIntent.
    ///
    /// Start another cycle when:
    /// - wake-check is enabled for this alarm (first cycle), or
    /// - a wake-check session already exists (continue existing pipeline even if
    ///   user toggled settings after the first cycle started).
    public static func shouldEnqueuePipelineOnStopIntent(
        wakeUpCheckEnabledForAlarm: Bool,
        hasActiveSession: Bool
    ) -> Bool {
        hasActiveSession || wakeUpCheckEnabledForAlarm
    }

    /// Repeated cycles keep using the persisted snapshot captured when pipeline
    /// execution started so timing stays stable until explicit confirmation.
    public static func configSnapshotForNextCycle(
        previousSession: WakeUpCheckSessionState?,
        fallbackSnapshot: WakeUpCheckConfigSnapshot
    ) -> WakeUpCheckConfigSnapshot {
        previousSession?.configSnapshot ?? fallbackSnapshot
    }

    /// Policy constant used by runtime scheduling: wake-check alarms never show
    /// snooze to keep the confirmation loop strict.
    public static var wakeCheckAlarmsDisableSnooze: Bool {
        true
    }

    public static func nextCycleSession(
        alarmID: UUID,
        previousSession: WakeUpCheckSessionState?,
        fallbackSnapshot: WakeUpCheckConfigSnapshot,
        now: Date,
        makeNotificationID: (UUID, Int) -> String
    ) -> WakeUpCheckSessionState {
        WakeUpCheckStateMachine.nextCycle(
            alarmID: alarmID,
            previousSession: previousSession,
            configSnapshot: configSnapshotForNextCycle(
                previousSession: previousSession,
                fallbackSnapshot: fallbackSnapshot
            ),
            now: now,
            makeNotificationID: makeNotificationID
        )
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
/// For modify-next-earlier, `overrideDate < restoreAnchorDate`.
/// The override ring is consumed first, the usual-time canonical slot is skipped,
/// and recurring restore happens from the first manual bridge at/after anchor.
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
            var candidates: [Date] = []

            if let overrideDate = overrideState.overrideDate,
               overrideDate > now {
                candidates.append(overrideDate)
            }

            // Canonical bridges intentionally start strictly after restore anchor,
            // so the overridden canonical slot is not reintroduced as a second ring.
            let bridgeSeed = max(now, overrideState.restoreAnchorDate)
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

    /// Consumption criterion for the explicit modify-next override ring.
    ///
    /// Once consumed, callers should clear display/persistence fields tied to the
    /// one-off override so stale override times do not leak to later days.
    public static func shouldConsumeOverrideDate(
        afterManualAlarmFiredAt firedAt: Date,
        overrideState: AlarmTemporaryScheduleOverride
    ) -> Bool {
        guard overrideState.kind == .modifyNext,
              let overrideDate = overrideState.overrideDate else {
            return false
        }

        return firedAt >= overrideDate
    }

    /// Restore criterion used by callbacks and cold-start recovery.
    ///
    /// This single inequality unifies all flows:
    /// - disable-next: first bridge date equals restore anchor
    /// - modify-next: restore from first manual bridge fired at/after anchor
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
