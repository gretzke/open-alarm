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
    public static let responseTimeoutOptionsMinutes: [Int] = [1, 2, 3, 5, 10, 20]

    public static func clampCheckDelayMinutes(_ minutes: Int) -> Int {
        min(60, max(1, minutes))
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
}
