// This file provides the minimal type surface needed by AlarmStateMachine.
// It re-exports nothing; the full AlarmDefinition in Models/ is the source of truth.
// This file exists solely so the SPM OpenAlarmSchedulingCore target can compile
// without depending on AlarmKit or UIKit.
//
// NOTE: When building inside the Xcode project this file is NOT included —
//       the real AlarmDefinition.swift supplies everything.

#if OPENALARM_SCHEDULING_CORE_SPM

import Foundation

// MARK: - Alarm Type

enum AlarmType: Codable, Equatable, Sendable {
    case regular
    case nap(NapConfig)
    case tryOut

    private enum FlatType: String, Codable {
        case regular, nap, tryOut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let flat = try container.decode(FlatType.self)
        switch flat {
        case .regular: self = .regular
        case .nap: self = .nap(NapConfig(durationMinutes: 0, pausedRemainingSeconds: nil))
        case .tryOut: self = .tryOut
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .regular: try container.encode(FlatType.regular)
        case .nap: try container.encode(FlatType.nap)
        case .tryOut: try container.encode(FlatType.tryOut)
        }
    }
}

// MARK: - Settings Mode

enum SettingsMode: Codable, Equatable, Sendable {
    case useDefault
    case custom(SharedAlarmSettings)
}

// MARK: - Alarm Lifecycle State

enum AlarmLifecycleState: String, Codable, CaseIterable, Sendable {
    case scheduled
    case alerting
    case awaitingDisarmChallenge
    case awaitingWakeCheck
    case completed
}

// MARK: - Alarm Type Key

enum AlarmTypeKey: String, Codable, CaseIterable, Sendable {
    case regular, nap, tryOut
}

// MARK: - Trigger

enum AlarmTrigger: Codable, Equatable, Sendable {
    case time(hour: Int, minute: Int)
    case fixed(Date)
}

// MARK: - Recurrence

enum AlarmRecurrence: Codable, Equatable, Sendable {
    case none
    case weekly([AlarmWeekday])

    var weekdays: [AlarmWeekday] {
        switch self {
        case .none: return []
        case .weekly(let days): return days.sorted { $0.rawValue < $1.rawValue }
        }
    }
}

struct NapConfig: Codable, Equatable, Sendable {
    var durationMinutes: Int
    var pausedRemainingSeconds: TimeInterval?
    var isPaused: Bool { pausedRemainingSeconds != nil }
}

// MARK: - Weekday

enum AlarmWeekday: Int, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case sunday = 1, monday = 2, tuesday = 3, wednesday = 4
    case thursday = 5, friday = 6, saturday = 7

    var id: Int { rawValue }
}

// MARK: - Disarm Tasks

enum MathDifficulty: String, Codable, CaseIterable, Sendable {
    case simple
    case hard
}

enum AlarmTask: Codable, Equatable, Sendable {
    case dummy
    case math(difficulty: MathDifficulty, count: Int)
}

// MARK: - AlarmVolumeSettings

struct AlarmVolumeSettings: Codable, Equatable, Sendable {
    var targetPercent: Int

    static let `default` = AlarmVolumeSettings(targetPercent: 20)

    init(targetPercent: Int = 20) {
        self.targetPercent = Self.clamp(targetPercent)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetPercent = Self.clamp(try container.decodeIfPresent(Int.self, forKey: .targetPercent) ?? Self.default.targetPercent)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetPercent, forKey: .targetPercent)
    }

    private enum CodingKeys: String, CodingKey {
        case targetPercent
    }

    static func clamp(_ percent: Int) -> Int {
        min(100, max(0, percent))
    }

    var targetScalar: Float {
        Float(targetPercent) / 100
    }
}

// MARK: - Minimal SharedAlarmSettings (stub for Codable conformance)

struct SharedAlarmSettings: Codable, Equatable, Sendable {
    var snoozeEnabled: Bool
    var snoozeDurationMinutes: Int
    var maxSnoozes: Int?
    var wakeUpCheckEnabled: Bool
    var wakeUpCheckDelayMinutes: Int
    var wakeUpCheckResponseTimeoutMinutes: Int
    var tasks: [AlarmTask]
    var volume: AlarmVolumeSettings

    static let featureDefaults = SharedAlarmSettings(
        snoozeEnabled: false,
        snoozeDurationMinutes: 5,
        maxSnoozes: 3,
        wakeUpCheckEnabled: false,
        wakeUpCheckDelayMinutes: 5,
        wakeUpCheckResponseTimeoutMinutes: 3,
        tasks: [],
        volume: .default
    )

    private enum CodingKeys: String, CodingKey {
        case snoozeEnabled
        case snoozeDurationMinutes
        case maxSnoozes
        case wakeUpCheckEnabled
        case wakeUpCheckDelayMinutes
        case wakeUpCheckResponseTimeoutMinutes
        case tasks
        case volume
    }

    init(
        snoozeEnabled: Bool,
        snoozeDurationMinutes: Int,
        maxSnoozes: Int?,
        wakeUpCheckEnabled: Bool,
        wakeUpCheckDelayMinutes: Int,
        wakeUpCheckResponseTimeoutMinutes: Int,
        tasks: [AlarmTask] = [],
        volume: AlarmVolumeSettings = .default
    ) {
        self.snoozeEnabled = snoozeEnabled
        self.snoozeDurationMinutes = snoozeDurationMinutes
        self.maxSnoozes = maxSnoozes
        self.wakeUpCheckEnabled = wakeUpCheckEnabled
        self.wakeUpCheckDelayMinutes = wakeUpCheckDelayMinutes
        self.wakeUpCheckResponseTimeoutMinutes = wakeUpCheckResponseTimeoutMinutes
        self.tasks = tasks
        self.volume = volume
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snoozeEnabled = try container.decodeIfPresent(Bool.self, forKey: .snoozeEnabled) ?? SharedAlarmSettings.featureDefaults.snoozeEnabled
        snoozeDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .snoozeDurationMinutes) ?? SharedAlarmSettings.featureDefaults.snoozeDurationMinutes
        maxSnoozes = try container.decodeIfPresent(Int.self, forKey: .maxSnoozes) ?? SharedAlarmSettings.featureDefaults.maxSnoozes
        wakeUpCheckEnabled = try container.decodeIfPresent(Bool.self, forKey: .wakeUpCheckEnabled) ?? SharedAlarmSettings.featureDefaults.wakeUpCheckEnabled
        wakeUpCheckDelayMinutes = try container.decodeIfPresent(Int.self, forKey: .wakeUpCheckDelayMinutes) ?? SharedAlarmSettings.featureDefaults.wakeUpCheckDelayMinutes
        wakeUpCheckResponseTimeoutMinutes = try container.decodeIfPresent(Int.self, forKey: .wakeUpCheckResponseTimeoutMinutes) ?? SharedAlarmSettings.featureDefaults.wakeUpCheckResponseTimeoutMinutes
        tasks = try container.decodeIfPresent([AlarmTask].self, forKey: .tasks) ?? []
        volume = try container.decodeIfPresent(AlarmVolumeSettings.self, forKey: .volume) ?? .default
    }
}

// MARK: - Override State

enum OverrideKind: String, Codable, Equatable, Sendable {
    case skipNext
    case modifyNext
}

struct OverrideState: Codable, Equatable, Sendable {
    var kind: OverrideKind
    var bridgeAlarmIDs: [UUID]  // ordered by fire date, 5 entries
    var restoreAnchorDate: Date
}

// MARK: - Minimal AlarmDefinition

struct AlarmDefinition: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var trigger: AlarmTrigger
    var recurrence: AlarmRecurrence
    var type: AlarmType
    var deleteAfterUse: Bool
    var settingsMode: SettingsMode
    var nextTriggerOverrideDate: Date?
    var isEnabled: Bool
    var activeOverride: OverrideState?
    var snoozeCount: Int
    var lifecycleState: AlarmLifecycleState
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "",
        trigger: AlarmTrigger = .time(hour: 0, minute: 0),
        recurrence: AlarmRecurrence = .none,
        type: AlarmType = .regular,
        deleteAfterUse: Bool = true,
        settingsMode: SettingsMode = .useDefault,
        nextTriggerOverrideDate: Date? = nil,
        isEnabled: Bool = true,
        activeOverride: OverrideState? = nil,
        snoozeCount: Int = 0,
        lifecycleState: AlarmLifecycleState = .scheduled,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.recurrence = recurrence
        self.type = type
        self.deleteAfterUse = deleteAfterUse
        self.settingsMode = settingsMode
        self.nextTriggerOverrideDate = nextTriggerOverrideDate
        self.isEnabled = isEnabled
        self.activeOverride = activeOverride
        self.snoozeCount = snoozeCount
        self.lifecycleState = lifecycleState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var repeatDays: [AlarmWeekday] {
        switch recurrence {
        case .none: return []
        case .weekly(let days): return days.sorted { $0.rawValue < $1.rawValue }
        }
    }

    var isRepeating: Bool { !repeatDays.isEmpty }

    var isNap: Bool {
        if case .nap = type { return true }
        return false
    }

    var isTryOut: Bool {
        if case .tryOut = type { return true }
        return false
    }
}

typealias UserAlarm = AlarmDefinition

#endif
