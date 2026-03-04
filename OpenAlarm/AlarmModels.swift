import AlarmKit
import Foundation

struct OpenAlarmMetadata: AlarmMetadata {
    var source: String
    var isShadowTrial: Bool
    var createdAt: Date

    init(source: String, isShadowTrial: Bool) {
        self.source = source
        self.isShadowTrial = isShadowTrial
        self.createdAt = .now
    }
}

enum AlarmType: String, Codable, CaseIterable, Sendable {
    case regular
    case nap
    case tryOut
}

enum AlarmTypePolicy {
    /// Normalizes alarm fields on write based on alarm type.
    /// Forces `deleteAfterUse = true` for nap and tryOut types.
    static func normalizeOnWrite(_ alarm: inout UserAlarm) {
        switch alarm.alarmType {
        case .nap, .tryOut:
            alarm.deleteAfterUse = true
        case .regular:
            break
        }
    }
}

enum AlarmLifecycleState: String, Codable, CaseIterable, Sendable {
    case scheduled
    case alerting
    case awaitingWakeCheck
    case completed
}

enum AlarmWeekday: Int, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    var id: Int { rawValue }

    var localeWeekday: Locale.Weekday {
        switch self {
        case .sunday: .sunday
        case .monday: .monday
        case .tuesday: .tuesday
        case .wednesday: .wednesday
        case .thursday: .thursday
        case .friday: .friday
        case .saturday: .saturday
        }
    }

    static func orderedForCurrentLocale(calendar: Calendar = .autoupdatingCurrent) -> [AlarmWeekday] {
        let first = calendar.firstWeekday
        guard let firstIndex = AlarmWeekday.allCases.firstIndex(where: { $0.rawValue == first }) else {
            return AlarmWeekday.allCases
        }

        let head = AlarmWeekday.allCases[firstIndex...]
        let tail = AlarmWeekday.allCases[..<firstIndex]
        return Array(head + tail)
    }

    func veryShortSymbol(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale

        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? formatter.veryShortWeekdaySymbols ?? []
        guard symbols.count >= 7 else {
            return fallbackSymbol
        }
        return symbols[rawValue - 1]
    }

    private var fallbackSymbol: String {
        switch self {
        case .sunday: return "S"
        case .monday: return "M"
        case .tuesday: return "T"
        case .wednesday: return "W"
        case .thursday: return "T"
        case .friday: return "F"
        case .saturday: return "S"
        }
    }
}


enum AlarmFeatureRequirement: Hashable, Sendable {
    case notifications
}

struct SharedAlarmSettings: Codable, Equatable, Sendable {
    var snoozeEnabled: Bool
    var snoozeDurationMinutes: Int
    var maxSnoozes: Int?
    var wakeUpCheckEnabled: Bool
    var wakeUpCheckDelayMinutes: Int
    var wakeUpCheckResponseTimeoutMinutes: Int

    static let featureDefaults = SharedAlarmSettings(
        snoozeEnabled: false,
        snoozeDurationMinutes: 5,
        maxSnoozes: 3,
        wakeUpCheckEnabled: false,
        wakeUpCheckDelayMinutes: WakeUpCheckTimingPolicy.defaultCheckDelayMinutes,
        wakeUpCheckResponseTimeoutMinutes: WakeUpCheckTimingPolicy.defaultResponseTimeoutMinutes
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
    }

    init(
        snoozeEnabled: Bool,
        snoozeDurationMinutes: Int,
        maxSnoozes: Int?,
        wakeUpCheckEnabled: Bool,
        wakeUpCheckDelayMinutes: Int,
        wakeUpCheckResponseTimeoutMinutes: Int
    ) {
        self.snoozeEnabled = snoozeEnabled
        self.snoozeDurationMinutes = snoozeDurationMinutes
        self.maxSnoozes = maxSnoozes
        self.wakeUpCheckEnabled = wakeUpCheckEnabled
        self.wakeUpCheckDelayMinutes = WakeUpCheckTimingPolicy.clampCheckDelayMinutes(wakeUpCheckDelayMinutes)
        self.wakeUpCheckResponseTimeoutMinutes = WakeUpCheckTimingPolicy.normalizeResponseTimeoutMinutes(wakeUpCheckResponseTimeoutMinutes)
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
    }
}

struct UserAlarm: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var hour: Int
    var minute: Int
    var repeatDays: [AlarmWeekday]
    var deleteAfterUse: Bool
    var alarmType: AlarmType
    var fixedTriggerDate: Date?
    var durationMinutes: Int?
    var pausedRemainingSeconds: TimeInterval?

    var useDefaultSharedSettings: Bool
    var customSharedSettings: SharedAlarmSettings

    /// Stable identifier used by temporary manual one-shots to reference alarm
    /// configuration independently from runtime AlarmKit alarm IDs.
    var scheduleConfigReferenceID: UUID

    /// Legacy UI/display field (kept for compatibility): next modified one-shot
    /// date chosen by "Apply next only".
    var nextTriggerOverrideDate: Date?

    var isEnabled: Bool

    /// Legacy UI/display field (kept for compatibility): skipped canonical date
    /// for disable-next banners.
    var skipNextUntilDate: Date?

    var snoozeCount: Int

    /// Unified temporary override state used by scheduling planner/reconciler.
    var temporaryScheduleOverride: AlarmTemporaryScheduleOverride?

    /// Explicit manual AlarmKit one-shot queue used while override is active.
    var manualScheduleQueue: [AlarmManualScheduleEntry]

    var lifecycleState: AlarmLifecycleState
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        name: String,
        hour: Int,
        minute: Int,
        repeatDays: [AlarmWeekday],
        deleteAfterUse: Bool,
        alarmType: AlarmType = .regular,
        fixedTriggerDate: Date? = nil,
        durationMinutes: Int? = nil,
        pausedRemainingSeconds: TimeInterval? = nil,
        useDefaultSharedSettings: Bool,
        customSharedSettings: SharedAlarmSettings,
        scheduleConfigReferenceID: UUID,
        nextTriggerOverrideDate: Date?,
        isEnabled: Bool,
        skipNextUntilDate: Date?,
        snoozeCount: Int,
        temporaryScheduleOverride: AlarmTemporaryScheduleOverride?,
        manualScheduleQueue: [AlarmManualScheduleEntry],
        lifecycleState: AlarmLifecycleState,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hour = hour
        self.minute = minute
        self.repeatDays = repeatDays.sorted { $0.rawValue < $1.rawValue }
        self.deleteAfterUse = deleteAfterUse
        self.alarmType = alarmType
        self.fixedTriggerDate = fixedTriggerDate
        self.durationMinutes = durationMinutes
        self.pausedRemainingSeconds = pausedRemainingSeconds
        self.useDefaultSharedSettings = useDefaultSharedSettings
        self.customSharedSettings = customSharedSettings
        self.scheduleConfigReferenceID = scheduleConfigReferenceID
        self.nextTriggerOverrideDate = nextTriggerOverrideDate
        self.isEnabled = isEnabled
        self.skipNextUntilDate = skipNextUntilDate
        self.snoozeCount = snoozeCount
        self.temporaryScheduleOverride = temporaryScheduleOverride
        self.manualScheduleQueue = manualScheduleQueue.sorted { $0.triggerDate < $1.triggerDate }
        self.lifecycleState = lifecycleState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isRepeating: Bool {
        !repeatDays.isEmpty
    }

    var isSkippingNext: Bool {
        !isEnabled && skipNextUntilDate != nil
    }

    var isFullyDisabled: Bool {
        !isEnabled && skipNextUntilDate == nil
    }

    var isNap: Bool { alarmType == .nap }
    var isTryOut: Bool { alarmType == .tryOut }
    var isPaused: Bool { pausedRemainingSeconds != nil }

    /// Remaining seconds for a nap alarm (paused or counting down to fixedTriggerDate).
    func remainingSeconds(referenceDate: Date = .now) -> TimeInterval {
        if let pausedRemainingSeconds {
            return max(0, pausedRemainingSeconds)
        }
        guard let target = fixedTriggerDate else { return 0 }
        return max(0, target.timeIntervalSince(referenceDate))
    }

    /// Creates a nap-typed UserAlarm from a NapDraft.
    static func makeNap(
        from draft: NapDraft,
        defaultSharedSettings: SharedAlarmSettings,
        targetDate: Date,
        now: Date = .now
    ) -> UserAlarm {
        let customSettings = draft.useDefaultSharedSettings ? defaultSharedSettings : draft.customSharedSettings
        let id = UUID()
        var alarm = UserAlarm(
            id: id,
            name: "",
            hour: 0,
            minute: 0,
            repeatDays: [],
            deleteAfterUse: true,
            alarmType: .nap,
            fixedTriggerDate: targetDate,
            durationMinutes: draft.totalMinutes,
            pausedRemainingSeconds: nil,
            useDefaultSharedSettings: draft.useDefaultSharedSettings,
            customSharedSettings: customSettings,
            scheduleConfigReferenceID: id,
            nextTriggerOverrideDate: nil,
            isEnabled: true,
            skipNextUntilDate: nil,
            snoozeCount: 0,
            temporaryScheduleOverride: nil,
            manualScheduleQueue: [],
            lifecycleState: .scheduled,
            createdAt: now,
            updatedAt: now
        )
        AlarmTypePolicy.normalizeOnWrite(&alarm)
        return alarm
    }

    var canonicalScheduleSpec: AlarmCanonicalScheduleSpec {
        AlarmCanonicalScheduleSpec(
            weekdayNumbers: sortedRepeatDays.map(\.rawValue),
            hour: hour,
            minute: minute,
            isEnabled: true
        )
    }

    var triggerDateForDisplay: Date {
        if let nextTriggerOverrideDate {
            return nextTriggerOverrideDate
        }

        var components = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: .now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return Calendar.autoupdatingCurrent.date(from: components) ?? .now
    }

    var sortedRepeatDays: [AlarmWeekday] {
        repeatDays.sorted { $0.rawValue < $1.rawValue }
    }

    /// Canonical schedule only. Temporary overrides are handled by manual queue
    /// scheduling and must not mutate this payload.
    var schedule: Alarm.Schedule {
        let time = Alarm.Schedule.Relative.Time(hour: hour, minute: minute)
        if repeatDays.isEmpty {
            return .relative(.init(time: time, repeats: .never))
        }

        return .relative(.init(
            time: time,
            repeats: .weekly(sortedRepeatDays.map(\.localeWeekday))
        ))
    }

    func resolvedSharedSettings(defaults: SharedAlarmSettings) -> SharedAlarmSettings {
        useDefaultSharedSettings ? defaults : customSharedSettings
    }

    func canSnoozeAgain(defaults: SharedAlarmSettings) -> Bool {
        resolvedSharedSettings(defaults: defaults).canSnoozeAgain(currentCount: snoozeCount)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case hour
        case minute
        case repeatDays
        case deleteAfterUse
        case alarmType
        case fixedTriggerDate
        case durationMinutes
        case pausedRemainingSeconds
        case wakeUpCheckEnabled // legacy migration key
        case wakeUpCheckDelayMinutes // legacy migration key
        case useDefaultSharedSettings
        case customSharedSettings
        case scheduleConfigReferenceID
        case nextTriggerOverrideDate
        case isEnabled
        case skipNextUntilDate
        case snoozeCount
        case temporaryScheduleOverride
        case manualScheduleQueue
        case lifecycleState
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = (try container.decodeIfPresent(String.self, forKey: .name) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        hour = try container.decode(Int.self, forKey: .hour)
        minute = try container.decode(Int.self, forKey: .minute)
        repeatDays = (try container.decodeIfPresent([AlarmWeekday].self, forKey: .repeatDays) ?? [])
            .sorted { $0.rawValue < $1.rawValue }
        deleteAfterUse = try container.decodeIfPresent(Bool.self, forKey: .deleteAfterUse) ?? true
        alarmType = try container.decodeIfPresent(AlarmType.self, forKey: .alarmType) ?? .regular
        fixedTriggerDate = try container.decodeIfPresent(Date.self, forKey: .fixedTriggerDate)
        durationMinutes = try container.decodeIfPresent(Int.self, forKey: .durationMinutes)
        pausedRemainingSeconds = try container.decodeIfPresent(Double.self, forKey: .pausedRemainingSeconds)

        customSharedSettings = try container.decodeIfPresent(SharedAlarmSettings.self, forKey: .customSharedSettings) ?? .featureDefaults
        useDefaultSharedSettings = try container.decodeIfPresent(Bool.self, forKey: .useDefaultSharedSettings) ?? true

        // Legacy migration: older builds stored wake-check values on UserAlarm instead of SharedAlarmSettings.
        if let legacyWakeEnabled = try container.decodeIfPresent(Bool.self, forKey: .wakeUpCheckEnabled) {
            customSharedSettings.wakeUpCheckEnabled = legacyWakeEnabled
        }
        if let legacyWakeDelay = try container.decodeIfPresent(Int.self, forKey: .wakeUpCheckDelayMinutes) {
            customSharedSettings.wakeUpCheckDelayMinutes = WakeUpCheckTimingPolicy.clampCheckDelayMinutes(legacyWakeDelay)
        }

        scheduleConfigReferenceID = try container.decodeIfPresent(UUID.self, forKey: .scheduleConfigReferenceID) ?? id
        nextTriggerOverrideDate = try container.decodeIfPresent(Date.self, forKey: .nextTriggerOverrideDate)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        skipNextUntilDate = try container.decodeIfPresent(Date.self, forKey: .skipNextUntilDate)

        snoozeCount = try container.decodeIfPresent(Int.self, forKey: .snoozeCount) ?? 0

        temporaryScheduleOverride = try container.decodeIfPresent(AlarmTemporaryScheduleOverride.self, forKey: .temporaryScheduleOverride)
        manualScheduleQueue = (try container.decodeIfPresent([AlarmManualScheduleEntry].self, forKey: .manualScheduleQueue) ?? [])
            .sorted { $0.triggerDate < $1.triggerDate }

        lifecycleState = try container.decodeIfPresent(AlarmLifecycleState.self, forKey: .lifecycleState) ?? .scheduled
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(hour, forKey: .hour)
        try container.encode(minute, forKey: .minute)
        try container.encode(repeatDays, forKey: .repeatDays)
        try container.encode(deleteAfterUse, forKey: .deleteAfterUse)
        try container.encode(alarmType, forKey: .alarmType)
        try container.encodeIfPresent(fixedTriggerDate, forKey: .fixedTriggerDate)
        try container.encodeIfPresent(durationMinutes, forKey: .durationMinutes)
        try container.encodeIfPresent(pausedRemainingSeconds, forKey: .pausedRemainingSeconds)
        try container.encode(useDefaultSharedSettings, forKey: .useDefaultSharedSettings)
        try container.encode(customSharedSettings, forKey: .customSharedSettings)
        try container.encode(scheduleConfigReferenceID, forKey: .scheduleConfigReferenceID)
        try container.encodeIfPresent(nextTriggerOverrideDate, forKey: .nextTriggerOverrideDate)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(skipNextUntilDate, forKey: .skipNextUntilDate)
        try container.encode(snoozeCount, forKey: .snoozeCount)
        try container.encodeIfPresent(temporaryScheduleOverride, forKey: .temporaryScheduleOverride)
        try container.encode(manualScheduleQueue, forKey: .manualScheduleQueue)
        try container.encode(lifecycleState, forKey: .lifecycleState)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

struct NapDraft: Equatable {
    var durationHours: Int
    var durationMinutes: Int
    var useDefaultSharedSettings: Bool
    var customSharedSettings: SharedAlarmSettings

    init(
        totalMinutes: Int,
        useDefaultSharedSettings: Bool = true,
        customSharedSettings: SharedAlarmSettings
    ) {
        let clampedMinutes = max(1, totalMinutes)
        durationHours = clampedMinutes / 60
        durationMinutes = clampedMinutes % 60
        self.useDefaultSharedSettings = useDefaultSharedSettings
        self.customSharedSettings = customSharedSettings
    }

    var totalMinutes: Int {
        max(1, durationHours * 60 + durationMinutes)
    }

    mutating func applyDefaultSharedSettings(_ defaults: SharedAlarmSettings) {
        customSharedSettings = defaults
    }

    func resolvedSharedSettings(defaults: SharedAlarmSettings) -> SharedAlarmSettings {
        useDefaultSharedSettings ? defaults : customSharedSettings
    }
}

struct AlarmDraft: Equatable {
    var name: String
    var time: Date
    var repeatDays: Set<AlarmWeekday>
    var deleteAfterUse: Bool

    var useDefaultSharedSettings: Bool
    var customSharedSettings: SharedAlarmSettings

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
        self.useDefaultSharedSettings = useDefaultSharedSettings
        self.customSharedSettings = customSharedSettings
    }

    init(alarm: UserAlarm) {
        self.name = alarm.name
        self.time = alarm.triggerDateForDisplay
        self.repeatDays = Set(alarm.repeatDays)
        self.deleteAfterUse = alarm.deleteAfterUse
        self.useDefaultSharedSettings = alarm.useDefaultSharedSettings
        self.customSharedSettings = alarm.customSharedSettings
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
        customSharedSettings = defaults
    }

    func resolvedSharedSettings(defaults: SharedAlarmSettings) -> SharedAlarmSettings {
        useDefaultSharedSettings ? defaults : customSharedSettings
    }

    func toUserAlarm(
        id: UUID,
        existingCreatedAt: Date?,
        defaultSharedSettings: SharedAlarmSettings,
        existingScheduleConfigReferenceID: UUID? = nil,
        existingNextTriggerOverrideDate: Date? = nil,
        existingIsEnabled: Bool = true,
        existingSkipNextUntilDate: Date? = nil,
        existingSnoozeCount: Int?,
        existingTemporaryScheduleOverride: AlarmTemporaryScheduleOverride? = nil,
        existingManualScheduleQueue: [AlarmManualScheduleEntry] = [],
        alarmType: AlarmType = .regular
    ) -> UserAlarm {
        let timeComponents = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: time)
        let hour = timeComponents.hour ?? 7
        let minute = timeComponents.minute ?? 0
        let persistedCustomSharedSettings = useDefaultSharedSettings ? defaultSharedSettings : customSharedSettings

        return UserAlarm(
            id: id,
            name: name,
            hour: hour,
            minute: minute,
            repeatDays: Array(repeatDays),
            deleteAfterUse: deleteAfterUse,
            alarmType: alarmType,
            useDefaultSharedSettings: useDefaultSharedSettings,
            customSharedSettings: persistedCustomSharedSettings,
            scheduleConfigReferenceID: existingScheduleConfigReferenceID ?? id,
            nextTriggerOverrideDate: existingNextTriggerOverrideDate,
            isEnabled: existingIsEnabled,
            skipNextUntilDate: existingSkipNextUntilDate,
            snoozeCount: existingSnoozeCount ?? 0,
            temporaryScheduleOverride: existingTemporaryScheduleOverride,
            manualScheduleQueue: existingManualScheduleQueue,
            lifecycleState: .scheduled,
            createdAt: existingCreatedAt ?? .now,
            updatedAt: .now
        )
    }
}

extension Collection where Element == AlarmWeekday {
    func repeatSummary() -> String {
        let sorted = self.sorted { $0.rawValue < $1.rawValue }
        return sorted
            .map { $0.veryShortSymbol() }
            .joined(separator: " ")
    }
}

// MARK: - Temporary schedule override helpers

extension UserAlarm {
    /// Clears temporary schedule override state (skip-next, modify-next) and
    /// optionally restores the enabled flag. Shared by both `AlarmStore` and
    /// `AlarmScheduleCoordinator` so the mutation lives on the value type.
    mutating func clearTemporaryScheduleOverride(
        restoreEnabledState: Bool?,
        clearManualQueue: Bool,
        updatedAt: Date
    ) {
        if let restoreEnabledState {
            isEnabled = restoreEnabledState
        }

        nextTriggerOverrideDate = nil
        skipNextUntilDate = nil
        temporaryScheduleOverride = nil

        if clearManualQueue {
            manualScheduleQueue.removeAll()
        }

        self.updatedAt = updatedAt
    }
}

// MARK: - Typed runtime schedule resolver

/// Resolves the correct `Alarm.Schedule` for runtime scheduling based on alarm type.
///
/// Regular alarms use the canonical relative schedule (hour/minute/weekdays).
/// Nap and tryOut alarms use their `fixedTriggerDate` as a one-shot fixed schedule.
/// This prevents one-shot types from being re-armed with a wrong relative schedule
/// during runtime convergence or wake-check completion.
enum AlarmScheduleResolver {
    /// Returns the appropriate runtime schedule for an alarm.
    ///
    /// - For nap/tryOut: returns `.fixed(fixedTriggerDate)` when available.
    /// - For regular (or nap/tryOut without fixedTriggerDate): returns `alarm.schedule`.
    static func runtimeSchedule(for alarm: UserAlarm) -> Alarm.Schedule {
        switch alarm.alarmType {
        case .nap, .tryOut:
            if let fixedDate = alarm.fixedTriggerDate {
                return .fixed(fixedDate)
            }
            // Fallback: should not happen for well-formed nap/tryOut, but
            // degrade gracefully to canonical schedule.
            return alarm.schedule
        case .regular:
            return alarm.schedule
        }
    }
}
