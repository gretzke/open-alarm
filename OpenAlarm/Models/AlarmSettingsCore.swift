import Foundation

// Foundation-only model layer. This file is compiled both in the app target and
// in the OpenAlarmSchedulingCore SPM package (see Package.swift), so it must not
// import AlarmKit, UIKit, or SwiftUI.

// MARK: - Scheduling Constants

/// Central home for scheduling magic numbers (D-7).
enum SchedulingConstants {
    /// Number of one-shot bridge alarms materialized for an override (EC-002 rolling window).
    static let bridgeWindowSize = 5
    /// "0 minutes" testing sentinel resolves to this many seconds (naps, snooze, wake-check timings).
    static let debugSentinelSeconds: TimeInterval = 5
    /// Interval for StopIntent's locked-context disarm backstop loop.
    static let disarmBackstopSeconds: TimeInterval = 30
    /// How long a past firing registration remains resolvable after its AlarmKit ID is no longer active.
    static let referenceRetentionSeconds: TimeInterval = 24 * 60 * 60
    /// Window in which a due bridge may be ringing before StopIntent writes its pending-disarm ID.
    static let dueBridgeGraceSeconds: TimeInterval = 15 * 60
    /// Forward window in which a future-dated bridge reference means a snoozed
    /// instance in flight (snooze durations go up to 60 minutes) rather than a
    /// sibling occurrence.
    static let snoozedBridgeHorizonSeconds: TimeInterval = 65 * 60
    /// Minimum wake-check grace extension when opening from a notification tap.
    static let wakeCheckGraceMinimumSeconds: TimeInterval = 60
    /// Deep-link nap extension bounds.
    static let minNapExtensionDeepLinkMinutes = 1
    static let maxNapExtensionDeepLinkMinutes = 24 * 60
}

// MARK: - Stop Intent Policy

enum StopIntentPolicy {
    /// Whether StopIntent may cancel an intent ID it could not resolve to any
    /// alarm or bridge. An empty model cannot distinguish an orphaned
    /// registration from a missing/quarantined alarms blob, so it must not
    /// cancel anything.
    static func shouldCancelUnresolved(alarms: [AlarmDefinition]) -> Bool {
        !alarms.isEmpty
    }
}

// MARK: - Alarm Type Policy

enum AlarmTypePolicy {
    static func normalizeOnWrite(_ alarm: inout UserAlarm) {
        switch alarm.type {
        case .nap, .tryOut:
            alarm.deleteAfterUse = true
        case .regular:
            break
        }
    }
}

// MARK: - Alarm Lifecycle State

enum AlarmLifecycleState: String, Codable, CaseIterable, Sendable {
    case scheduled
    case alerting
    case awaitingDisarmChallenge
    case awaitingWakeCheck
    case completed
}

// MARK: - Alarm Feature Requirement

enum AlarmFeatureRequirement: Hashable, Sendable {
    case notifications
}

// MARK: - Wake-Up Check Timing Policy

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

    public static func normalizeResponseTimeoutMinutes(_ minutes: Int) -> Int {
        if minutes == debugFiveSecondSentinelMinutes {
            return debugFiveSecondSentinelMinutes
        }
        return max(1, minutes)
    }

    public static func checkDelayInterval(for minutes: Int) -> TimeInterval {
        let normalizedMinutes = clampCheckDelayMinutes(minutes)
        if normalizedMinutes == debugFiveSecondSentinelMinutes {
            return SchedulingConstants.debugSentinelSeconds
        }
        return TimeInterval(normalizedMinutes * 60)
    }

    public static func responseTimeoutInterval(for minutes: Int) -> TimeInterval {
        let normalizedMinutes = normalizeResponseTimeoutMinutes(minutes)
        if normalizedMinutes == debugFiveSecondSentinelMinutes {
            return SchedulingConstants.debugSentinelSeconds
        }
        return TimeInterval(normalizedMinutes * 60)
    }
}

// MARK: - Disarm Tasks

enum MathDifficulty: String, Codable, CaseIterable, Sendable {
    case easy
    case medium
    case hard
    case extreme
    case nightmare
}

enum AlarmTask: Codable, Equatable, Hashable, Sendable {
    case dummy
    case math(difficulty: MathDifficulty, count: Int)
    case shake(intensity: Int)
    case memory(difficulty: Int, rounds: Int)
    case steps(count: Int)
    case scanObject(objectClass: String)

    var displayName: String {
        switch self {
        case .dummy: String(localized: "task_dummy_name")
        case .math: String(localized: "task_math_name")
        case .shake: String(localized: "task_shake_name")
        case .memory: String(localized: "task_memory_name")
        case .steps: String(localized: "task_steps_name")
        case .scanObject: String(localized: "task_scan_name")
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard container.allKeys.count == 1 else {
            throw DecodingError.typeMismatch(
                AlarmTask.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected exactly one alarm task case."
                )
            )
        }

        if container.contains(.dummy) {
            self = .dummy
        } else if container.contains(.math) {
            let math = try container.nestedContainer(keyedBy: MathCodingKeys.self, forKey: .math)
            self = .math(
                difficulty: try math.decode(MathDifficulty.self, forKey: .difficulty),
                count: try math.decode(Int.self, forKey: .count)
            )
        } else if container.contains(.shake) {
            let shake = try container.nestedContainer(keyedBy: ShakeCodingKeys.self, forKey: .shake)
            let intensity = try shake.decode(Int.self, forKey: .intensity)
            self = .shake(intensity: min(max(intensity, 1), 5))
        } else if container.contains(.memory) {
            let memory = try container.nestedContainer(keyedBy: MemoryCodingKeys.self, forKey: .memory)
            let difficulty = try memory.decode(Int.self, forKey: .difficulty)
            let rounds = try memory.decode(Int.self, forKey: .rounds)
            self = .memory(
                difficulty: min(max(difficulty, 1), 5),
                rounds: min(max(rounds, 1), 5)
            )
        } else if container.contains(.steps) {
            let steps = try container.nestedContainer(keyedBy: StepsCodingKeys.self, forKey: .steps)
            self = .steps(count: try steps.decode(Int.self, forKey: .count))
        } else if container.contains(.scanObject) {
            let scanObject = try container.nestedContainer(keyedBy: ScanObjectCodingKeys.self, forKey: .scanObject)
            self = .scanObject(objectClass: try scanObject.decode(String.self, forKey: .objectClass))
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown alarm task case."
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .dummy:
            try container.encode([String: String](), forKey: .dummy)
        case let .math(difficulty, count):
            var math = container.nestedContainer(keyedBy: MathCodingKeys.self, forKey: .math)
            try math.encode(difficulty, forKey: .difficulty)
            try math.encode(count, forKey: .count)
        case let .shake(intensity):
            var shake = container.nestedContainer(keyedBy: ShakeCodingKeys.self, forKey: .shake)
            try shake.encode(min(max(intensity, 1), 5), forKey: .intensity)
        case let .memory(difficulty, rounds):
            var memory = container.nestedContainer(keyedBy: MemoryCodingKeys.self, forKey: .memory)
            try memory.encode(min(max(difficulty, 1), 5), forKey: .difficulty)
            try memory.encode(min(max(rounds, 1), 5), forKey: .rounds)
        case let .steps(count):
            var steps = container.nestedContainer(keyedBy: StepsCodingKeys.self, forKey: .steps)
            try steps.encode(count, forKey: .count)
        case let .scanObject(objectClass):
            var scanObject = container.nestedContainer(keyedBy: ScanObjectCodingKeys.self, forKey: .scanObject)
            try scanObject.encode(objectClass, forKey: .objectClass)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case dummy
        case math
        case shake
        case memory
        case steps
        case scanObject
    }

    private enum MathCodingKeys: String, CodingKey {
        case difficulty
        case count
    }

    private enum ShakeCodingKeys: String, CodingKey {
        case intensity
    }

    private enum MemoryCodingKeys: String, CodingKey {
        case difficulty
        case rounds
    }

    private enum StepsCodingKeys: String, CodingKey {
        case count
    }

    private enum ScanObjectCodingKeys: String, CodingKey {
        case objectClass
    }
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

// MARK: - SharedAlarmSettings

struct SharedAlarmSettings: Codable, Equatable, Sendable {
    var snoozeEnabled: Bool
    var snoozeDurationMinutes: Int
    var maxSnoozes: Int?
    var wakeUpCheckEnabled: Bool
    var wakeUpCheckDelayMinutes: Int
    var wakeUpCheckResponseTimeoutMinutes: Int
    var tasksEnabled: Bool
    var tasks: [AlarmTask]
    var volume: AlarmVolumeSettings
    var ringtoneID: String

    static let featureDefaults = SharedAlarmSettings(
        snoozeEnabled: false,
        snoozeDurationMinutes: 5,
        maxSnoozes: 3,
        wakeUpCheckEnabled: false,
        wakeUpCheckDelayMinutes: WakeUpCheckTimingPolicy.defaultCheckDelayMinutes,
        wakeUpCheckResponseTimeoutMinutes: WakeUpCheckTimingPolicy.defaultResponseTimeoutMinutes,
        tasksEnabled: true,
        tasks: [],
        volume: .default,
        ringtoneID: RingtoneCatalog.defaultToneID
    )

    func canSnoozeAgain(currentCount: Int) -> Bool {
        guard snoozeEnabled else {
            return false
        }

        guard let maxSnoozes else {
            return true
        }

        return currentCount < maxSnoozes
    }

    var featureRequirements: Set<AlarmFeatureRequirement> {
        var requirements = Set<AlarmFeatureRequirement>()

        if wakeUpCheckEnabled {
            requirements.insert(.notifications)
        }

        return requirements
    }

    func hasFeatureRequirement(_ requirement: AlarmFeatureRequirement) -> Bool {
        featureRequirements.contains(requirement)
    }

    private enum CodingKeys: String, CodingKey {
        case snoozeEnabled
        case snoozeDurationMinutes
        case maxSnoozes
        case wakeUpCheckEnabled
        case wakeUpCheckDelayMinutes
        case wakeUpCheckResponseTimeoutMinutes
        case tasksEnabled
        case tasks
        case volume
        case ringtoneID
    }

    init(
        snoozeEnabled: Bool,
        snoozeDurationMinutes: Int,
        maxSnoozes: Int?,
        wakeUpCheckEnabled: Bool,
        wakeUpCheckDelayMinutes: Int,
        wakeUpCheckResponseTimeoutMinutes: Int,
        tasksEnabled: Bool = true,
        tasks: [AlarmTask] = [],
        volume: AlarmVolumeSettings = .default,
        ringtoneID: String = RingtoneCatalog.defaultToneID
    ) {
        self.snoozeEnabled = snoozeEnabled
        self.snoozeDurationMinutes = snoozeDurationMinutes
        self.maxSnoozes = maxSnoozes
        self.wakeUpCheckEnabled = wakeUpCheckEnabled
        self.wakeUpCheckDelayMinutes = WakeUpCheckTimingPolicy.clampCheckDelayMinutes(wakeUpCheckDelayMinutes)
        self.wakeUpCheckResponseTimeoutMinutes = WakeUpCheckTimingPolicy.normalizeResponseTimeoutMinutes(wakeUpCheckResponseTimeoutMinutes)
        self.tasksEnabled = tasksEnabled
        self.tasks = tasks
        self.volume = volume
        self.ringtoneID = ringtoneID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snoozeEnabled = try container.decodeIfPresent(Bool.self, forKey: .snoozeEnabled) ?? SharedAlarmSettings.featureDefaults.snoozeEnabled
        snoozeDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .snoozeDurationMinutes) ?? SharedAlarmSettings.featureDefaults.snoozeDurationMinutes
        maxSnoozes = try container.decodeIfPresent(Int.self, forKey: .maxSnoozes) ?? SharedAlarmSettings.featureDefaults.maxSnoozes
        wakeUpCheckEnabled = try container.decodeIfPresent(Bool.self, forKey: .wakeUpCheckEnabled) ?? SharedAlarmSettings.featureDefaults.wakeUpCheckEnabled
        wakeUpCheckDelayMinutes = WakeUpCheckTimingPolicy.clampCheckDelayMinutes(
            try container.decodeIfPresent(Int.self, forKey: .wakeUpCheckDelayMinutes) ?? SharedAlarmSettings.featureDefaults.wakeUpCheckDelayMinutes
        )
        wakeUpCheckResponseTimeoutMinutes = WakeUpCheckTimingPolicy.normalizeResponseTimeoutMinutes(
            try container.decodeIfPresent(Int.self, forKey: .wakeUpCheckResponseTimeoutMinutes) ?? SharedAlarmSettings.featureDefaults.wakeUpCheckResponseTimeoutMinutes
        )
        tasksEnabled = try container.decodeIfPresent(Bool.self, forKey: .tasksEnabled) ?? true
        tasks = try container.decodeIfPresent([AlarmTask].self, forKey: .tasks) ?? []
        volume = try container.decodeIfPresent(AlarmVolumeSettings.self, forKey: .volume) ?? .default
        ringtoneID = try container.decodeIfPresent(String.self, forKey: .ringtoneID) ?? RingtoneCatalog.defaultToneID
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(snoozeEnabled, forKey: .snoozeEnabled)
        try container.encode(snoozeDurationMinutes, forKey: .snoozeDurationMinutes)
        try container.encodeIfPresent(maxSnoozes, forKey: .maxSnoozes)
        try container.encode(wakeUpCheckEnabled, forKey: .wakeUpCheckEnabled)
        try container.encode(wakeUpCheckDelayMinutes, forKey: .wakeUpCheckDelayMinutes)
        try container.encode(wakeUpCheckResponseTimeoutMinutes, forKey: .wakeUpCheckResponseTimeoutMinutes)
        try container.encode(tasksEnabled, forKey: .tasksEnabled)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(volume, forKey: .volume)
        try container.encode(ringtoneID, forKey: .ringtoneID)
    }
}

// MARK: - NapDraft

struct NapDraft: Equatable {
    var durationHours: Int
    var durationMinutes: Int
    var settingsMode: SettingsMode

    /// Cached default settings for pre-filling when user toggles to custom.
    private var cachedDefaults: SharedAlarmSettings

    var useDefaultSharedSettings: Bool {
        get {
            if case .useDefault = settingsMode { return true }
            return false
        }
        set {
            if newValue {
                settingsMode = .useDefault
            } else {
                settingsMode = .custom(cachedDefaults)
            }
        }
    }

    var customSharedSettings: SharedAlarmSettings {
        get {
            if case .custom(let settings) = settingsMode { return settings }
            return cachedDefaults
        }
        set {
            settingsMode = .custom(newValue)
        }
    }

    init(
        totalMinutes: Int,
        useDefaultSharedSettings: Bool = true,
        customSharedSettings: SharedAlarmSettings
    ) {
        let clampedMinutes = max(0, totalMinutes)
        durationHours = clampedMinutes / 60
        durationMinutes = clampedMinutes % 60
        self.cachedDefaults = customSharedSettings
        if useDefaultSharedSettings {
            self.settingsMode = .useDefault
        } else {
            self.settingsMode = .custom(customSharedSettings)
        }
    }

    var totalMinutes: Int {
        // 0 is valid (5-second testing mode nap)
        max(0, durationHours * 60 + durationMinutes)
    }

    mutating func applyDefaultSharedSettings(_ defaults: SharedAlarmSettings) {
        cachedDefaults = defaults
    }

    func resolvedSharedSettings(defaults: SharedAlarmSettings) -> SharedAlarmSettings {
        useDefaultSharedSettings ? defaults : customSharedSettings
    }
}

// MARK: - AlarmDraft

struct AlarmDraft: Equatable {
    var name: String
    var time: Date
    var repeatDays: Set<AlarmWeekday>
    var deleteAfterUse: Bool
    var settingsMode: SettingsMode

    /// Cached default settings for pre-filling when user toggles to custom.
    private var cachedDefaults: SharedAlarmSettings

    var useDefaultSharedSettings: Bool {
        get {
            if case .useDefault = settingsMode { return true }
            return false
        }
        set {
            if newValue {
                settingsMode = .useDefault
            } else {
                settingsMode = .custom(cachedDefaults)
            }
        }
    }

    var customSharedSettings: SharedAlarmSettings {
        get {
            if case .custom(let settings) = settingsMode { return settings }
            return cachedDefaults
        }
        set {
            settingsMode = .custom(newValue)
        }
    }

    init(
        name: String = "",
        time: Date = .now,
        repeatDays: Set<AlarmWeekday> = [],
        deleteAfterUse: Bool = true,
        useDefaultSharedSettings: Bool = true,
        customSharedSettings: SharedAlarmSettings = .featureDefaults
    ) {
        self.name = name
        self.time = time
        self.repeatDays = repeatDays
        self.deleteAfterUse = deleteAfterUse
        self.cachedDefaults = customSharedSettings
        if useDefaultSharedSettings {
            self.settingsMode = .useDefault
        } else {
            self.settingsMode = .custom(customSharedSettings)
        }
    }

    init(alarm: UserAlarm) {
        self.name = alarm.name
        self.time = alarm.triggerDateForDisplay
        self.repeatDays = Set(alarm.repeatDays)
        self.deleteAfterUse = alarm.deleteAfterUse
        self.settingsMode = alarm.settingsMode
        if case .custom(let settings) = alarm.settingsMode {
            self.cachedDefaults = settings
        } else {
            self.cachedDefaults = .featureDefaults
        }
    }

    mutating func toggleRepeatDay(_ day: AlarmWeekday) {
        if repeatDays.contains(day) {
            repeatDays.remove(day)
        } else {
            repeatDays.insert(day)
        }

        if !repeatDays.isEmpty {
            deleteAfterUse = false
        }
    }

    mutating func setDeleteAfterUse(_ value: Bool) {
        deleteAfterUse = value
        if value {
            repeatDays.removeAll()
        }
    }

    mutating func applyDefaultSharedSettings(_ defaults: SharedAlarmSettings) {
        cachedDefaults = defaults
    }

    func resolvedSharedSettings(defaults: SharedAlarmSettings) -> SharedAlarmSettings {
        useDefaultSharedSettings ? defaults : customSharedSettings
    }

    func toUserAlarm(
        id: UUID = UUID(),
        existingCreatedAt: Date? = nil,
        defaultSharedSettings: SharedAlarmSettings,
        alarmType: AlarmType = .regular
    ) -> UserAlarm {
        let timeComponents = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: time)
        let hour = timeComponents.hour ?? 7
        let minute = timeComponents.minute ?? 0

        let resolvedSettingsMode: SettingsMode = settingsMode

        let daysArray = Array(repeatDays)
        let alarmRecurrence: AlarmRecurrence = daysArray.isEmpty ? .none : .weekly(daysArray)

        return UserAlarm(
            id: id,
            name: name,
            trigger: .time(hour: hour, minute: minute),
            recurrence: alarmRecurrence,
            type: alarmType,
            deleteAfterUse: deleteAfterUse,
            settingsMode: resolvedSettingsMode,
            nextTriggerOverrideDate: nil,
            isEnabled: true,
            activeOverride: nil,
            snoozeCount: 0,
            lifecycleState: .scheduled,
            createdAt: existingCreatedAt ?? .now,
            updatedAt: .now
        )
    }
}

// MARK: - AlarmWeekday repeat summary

extension Collection where Element == AlarmWeekday {
    func repeatSummary() -> String {
        let sorted = self.sorted { $0.rawValue < $1.rawValue }
        return sorted
            .map { $0.veryShortSymbol() }
            .joined(separator: " ")
    }
}

// MARK: - WakeCheckSession

struct WakeCheckSession: Codable, Equatable, Sendable {
    var alarmID: UUID
    var cycle: Int
    var checkAt: Date
    var deadlineAt: Date
    var notificationID: String
    var modifiedDuringSession: Bool

    private enum CodingKeys: String, CodingKey {
        case alarmID, cycle, checkAt, deadlineAt, notificationID, modifiedDuringSession
    }

    init(
        alarmID: UUID,
        cycle: Int,
        checkAt: Date,
        deadlineAt: Date,
        notificationID: String,
        modifiedDuringSession: Bool = false
    ) {
        self.alarmID = alarmID
        self.cycle = cycle
        self.checkAt = checkAt
        self.deadlineAt = deadlineAt
        self.notificationID = notificationID
        self.modifiedDuringSession = modifiedDuringSession
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alarmID = try container.decode(UUID.self, forKey: .alarmID)
        cycle = try container.decode(Int.self, forKey: .cycle)
        checkAt = try container.decode(Date.self, forKey: .checkAt)
        deadlineAt = try container.decode(Date.self, forKey: .deadlineAt)
        notificationID = try container.decode(String.self, forKey: .notificationID)
        modifiedDuringSession = try container.decodeIfPresent(Bool.self, forKey: .modifiedDuringSession) ?? false
    }
}

// MARK: - AlarmStoreError

enum AlarmStoreError: Error {
    case permissionDenied
    case scheduleFailed
}
