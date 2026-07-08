import Foundation

// MARK: - Alarm Type (with associated values)

enum AlarmType: Codable, Equatable, Sendable {
    case regular
    case nap(NapConfig)
    case tryOut

    // MARK: - Codable (backward-compatible: persisted as flat string)

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

// MARK: - Alarm Definition

struct AlarmDefinition: Identifiable, Codable, Equatable, Sendable {
    // MARK: - Definition
    var id: UUID
    var name: String
    var trigger: AlarmTrigger
    var recurrence: AlarmRecurrence
    var type: AlarmType
    var deleteAfterUse: Bool
    var settingsMode: SettingsMode
    var createdAt: Date
    var updatedAt: Date

    // MARK: - Runtime state (persisted)
    var isEnabled: Bool
    var snoozeCount: Int
    var lifecycleState: AlarmLifecycleState
    var nextTriggerOverrideDate: Date?
    var activeOverride: OverrideState?

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
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trigger = trigger
        self.recurrence = {
            switch recurrence {
            case .none: return .none
            case .weekly(let days): return .weekly(days.sorted { $0.rawValue < $1.rawValue })
            }
        }()
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

    // MARK: - Computed Properties from trigger

    var hour: Int {
        switch trigger {
        case .time(let h, _): return h
        case .fixed(let date): return Calendar.autoupdatingCurrent.component(.hour, from: date)
        }
    }

    var minute: Int {
        switch trigger {
        case .time(_, let m): return m
        case .fixed(let date): return Calendar.autoupdatingCurrent.component(.minute, from: date)
        }
    }

    // MARK: - Computed Properties from recurrence

    var repeatDays: [AlarmWeekday] {
        switch recurrence {
        case .none: return []
        case .weekly(let days): return days.sorted { $0.rawValue < $1.rawValue }
        }
    }

    var sortedRepeatDays: [AlarmWeekday] { repeatDays }

    var isRepeating: Bool { !repeatDays.isEmpty }

    // MARK: - Computed Properties from type

    var isNap: Bool {
        if case .nap = type { return true }
        return false
    }

    var isTryOut: Bool {
        if case .tryOut = type { return true }
        return false
    }

    var isPaused: Bool { pausedRemainingSeconds != nil }

    /// Setting nil is intentionally a no-op — a fixed trigger cannot be
    /// cleared, only replaced (the trigger enum has no "empty" case).
    var fixedTriggerDate: Date? {
        get {
            if case .fixed(let date) = trigger { return date }
            return nil
        }
        set {
            if let date = newValue {
                trigger = .fixed(date)
            }
        }
    }

    var durationMinutes: Int? {
        get {
            if case .nap(let config) = type { return config.durationMinutes }
            return nil
        }
        set {
            if case .nap(var config) = type, let value = newValue {
                config.durationMinutes = value
                type = .nap(config)
            }
        }
    }

    var pausedRemainingSeconds: TimeInterval? {
        get {
            if case .nap(let config) = type { return config.pausedRemainingSeconds }
            return nil
        }
        set {
            if case .nap(var config) = type {
                config.pausedRemainingSeconds = newValue
                type = .nap(config)
            }
        }
    }

    // Legacy compat property — same as `type` since AlarmType now has associated values
    var alarmType: AlarmType {
        get { type }
        set { type = newValue }
    }

    var typeKey: AlarmTypeKey {
        switch type {
        case .regular: .regular
        case .nap: .nap
        case .tryOut: .tryOut
        }
    }

    // MARK: - Computed Properties from settingsMode

    var useDefaultSharedSettings: Bool {
        get {
            if case .useDefault = settingsMode { return true }
            return false
        }
        set {
            if newValue {
                settingsMode = .useDefault
            } else {
                // When switching to custom, preserve existing custom settings or use defaults
                if case .custom = settingsMode { return }
                settingsMode = .custom(.featureDefaults)
            }
        }
    }

    var customSharedSettings: SharedAlarmSettings {
        get {
            if case .custom(let settings) = settingsMode { return settings }
            return .featureDefaults
        }
        set {
            settingsMode = .custom(newValue)
        }
    }

    // MARK: - Override / Disable

    var isOverrideActive: Bool { activeOverride != nil }

    var isSkippingNext: Bool {
        !isEnabled && activeOverride?.kind == .skipNext
    }

    var isFullyDisabled: Bool {
        !isEnabled && activeOverride == nil
    }

    // MARK: - Remaining Seconds

    func remainingSeconds(referenceDate: Date = .now) -> TimeInterval {
        if let pausedRemainingSeconds {
            return max(0, pausedRemainingSeconds)
        }
        guard let target = fixedTriggerDate else { return 0 }
        return max(0, target.timeIntervalSince(referenceDate))
    }

    // MARK: - Make Nap

    static func makeNap(
        from draft: NapDraft,
        defaultSharedSettings: SharedAlarmSettings,
        targetDate: Date,
        now: Date = .now
    ) -> AlarmDefinition {
        let napSettingsMode: SettingsMode = draft.useDefaultSharedSettings
            ? .useDefault
            : .custom(draft.customSharedSettings)

        let id = UUID()
        var alarm = AlarmDefinition(
            id: id,
            name: "",
            trigger: .fixed(targetDate),
            recurrence: .none,
            type: .nap(NapConfig(durationMinutes: draft.totalMinutes, pausedRemainingSeconds: nil)),
            deleteAfterUse: true,
            settingsMode: napSettingsMode,
            nextTriggerOverrideDate: nil,
            isEnabled: true,
            activeOverride: nil,
            snoozeCount: 0,
            lifecycleState: .scheduled,
            createdAt: now,
            updatedAt: now
        )
        AlarmTypePolicy.normalizeOnWrite(&alarm)
        return alarm
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

    func resolvedSharedSettings(defaults: SharedAlarmSettings) -> SharedAlarmSettings {
        switch settingsMode {
        case .useDefault: return defaults
        case .custom(let settings): return settings
        }
    }

    func canSnoozeAgain(defaults: SharedAlarmSettings) -> Bool {
        resolvedSharedSettings(defaults: defaults).canSnoozeAgain(currentCount: snoozeCount)
    }

    // MARK: - Codable

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
        case wakeUpCheckEnabled
        case wakeUpCheckDelayMinutes
        case useDefaultSharedSettings
        case customSharedSettings
        case nextTriggerOverrideDate
        case isEnabled
        case activeOverride
        case skipNextUntilDate  // legacy, read-only for migration
        case snoozeCount
        case lifecycleState
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = (try container.decodeIfPresent(String.self, forKey: .name) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Read flat fields and construct new enum types
        let flatHour = try container.decode(Int.self, forKey: .hour)
        let flatMinute = try container.decode(Int.self, forKey: .minute)
        let flatFixedTriggerDate = try container.decodeIfPresent(Date.self, forKey: .fixedTriggerDate)
        let flatRepeatDays = (try container.decodeIfPresent([AlarmWeekday].self, forKey: .repeatDays) ?? [])
            .sorted { $0.rawValue < $1.rawValue }

        // Construct trigger
        if let fixedDate = flatFixedTriggerDate {
            trigger = .fixed(fixedDate)
        } else {
            trigger = .time(hour: flatHour, minute: flatMinute)
        }

        // Construct recurrence
        if flatRepeatDays.isEmpty {
            recurrence = .none
        } else {
            recurrence = .weekly(flatRepeatDays)
        }

        // Construct type
        let flatAlarmType = try container.decodeIfPresent(AlarmType.self, forKey: .alarmType) ?? .regular
        let flatDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .durationMinutes)
        let flatPausedRemainingSeconds = try container.decodeIfPresent(Double.self, forKey: .pausedRemainingSeconds)

        switch flatAlarmType {
        case .nap:
            type = .nap(NapConfig(
                durationMinutes: flatDurationMinutes ?? 0,
                pausedRemainingSeconds: flatPausedRemainingSeconds
            ))
        case .regular:
            type = .regular
        case .tryOut:
            type = .tryOut
        }

        deleteAfterUse = try container.decodeIfPresent(Bool.self, forKey: .deleteAfterUse) ?? true

        // Construct settingsMode
        var decodedCustomSettings = try container.decodeIfPresent(SharedAlarmSettings.self, forKey: .customSharedSettings) ?? .featureDefaults
        let flatUseDefault = try container.decodeIfPresent(Bool.self, forKey: .useDefaultSharedSettings) ?? true

        if let legacyWakeEnabled = try container.decodeIfPresent(Bool.self, forKey: .wakeUpCheckEnabled) {
            decodedCustomSettings.wakeUpCheckEnabled = legacyWakeEnabled
        }
        if let legacyWakeDelay = try container.decodeIfPresent(Int.self, forKey: .wakeUpCheckDelayMinutes) {
            decodedCustomSettings.wakeUpCheckDelayMinutes = WakeUpCheckTimingPolicy.clampCheckDelayMinutes(legacyWakeDelay)
        }

        if flatUseDefault {
            settingsMode = .useDefault
        } else {
            settingsMode = .custom(decodedCustomSettings)
        }

        nextTriggerOverrideDate = try container.decodeIfPresent(Date.self, forKey: .nextTriggerOverrideDate)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        activeOverride = try container.decodeIfPresent(OverrideState.self, forKey: .activeOverride)

        // Legacy migration: if old skipNextUntilDate exists but no activeOverride, clear skip state
        if activeOverride == nil {
            let legacySkipUntil = try container.decodeIfPresent(Date.self, forKey: .skipNextUntilDate)
            if legacySkipUntil != nil {
                isEnabled = true
            }
        }

        snoozeCount = try container.decodeIfPresent(Int.self, forKey: .snoozeCount) ?? 0

        lifecycleState = try container.decodeIfPresent(AlarmLifecycleState.self, forKey: .lifecycleState) ?? .scheduled
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        // Write flat fields for backward compatibility
        try container.encode(hour, forKey: .hour)
        try container.encode(minute, forKey: .minute)
        try container.encode(repeatDays, forKey: .repeatDays)
        try container.encode(deleteAfterUse, forKey: .deleteAfterUse)
        try container.encode(type, forKey: .alarmType)
        try container.encodeIfPresent(fixedTriggerDate, forKey: .fixedTriggerDate)
        try container.encodeIfPresent(durationMinutes, forKey: .durationMinutes)
        try container.encodeIfPresent(pausedRemainingSeconds, forKey: .pausedRemainingSeconds)
        try container.encode(useDefaultSharedSettings, forKey: .useDefaultSharedSettings)
        try container.encode(customSharedSettings, forKey: .customSharedSettings)
        try container.encodeIfPresent(nextTriggerOverrideDate, forKey: .nextTriggerOverrideDate)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(activeOverride, forKey: .activeOverride)
        try container.encode(snoozeCount, forKey: .snoozeCount)
        try container.encode(lifecycleState, forKey: .lifecycleState)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

// MARK: - UserAlarm typealias (bridge for gradual migration)

typealias UserAlarm = AlarmDefinition

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

// MARK: - Type key for settings cascade

enum AlarmTypeKey: String, Codable, CaseIterable, Sendable {
    case regular, nap, tryOut
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
        guard let firstIndex = allCases.firstIndex(where: { $0.rawValue == first }) else {
            return allCases
        }
        return Array(allCases[firstIndex...] + allCases[..<firstIndex])
    }

    func veryShortSymbol(
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? formatter.veryShortWeekdaySymbols ?? []
        guard symbols.count >= 7 else { return fallbackSymbol }
        return symbols[rawValue - 1]
    }

    private var fallbackSymbol: String {
        switch self {
        case .sunday: "S"
        case .monday: "M"
        case .tuesday: "T"
        case .wednesday: "W"
        case .thursday: "T"
        case .friday: "F"
        case .saturday: "S"
        }
    }
}
