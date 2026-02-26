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

struct SharedAlarmSettings: Codable, Equatable, Sendable {
    var snoozeEnabled: Bool
    var snoozeDurationMinutes: Int
    var maxSnoozes: Int?

    static let featureDefaults = SharedAlarmSettings(
        snoozeEnabled: false,
        snoozeDurationMinutes: 5,
        maxSnoozes: 3
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
}

struct UserAlarm: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var hour: Int
    var minute: Int
    var repeatDays: [AlarmWeekday]
    var deleteAfterUse: Bool
    var wakeUpCheckEnabled: Bool
    var wakeUpCheckDelayMinutes: Int
    var wakeUpCheckDisableSnoozeOnReAlert: Bool

    var useDefaultSharedSettings: Bool
    var customSharedSettings: SharedAlarmSettings
    var nextTriggerOverrideDate: Date?
    var isEnabled: Bool
    var skipNextUntilDate: Date?
    var snoozeCount: Int

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
        wakeUpCheckEnabled: Bool,
        wakeUpCheckDelayMinutes: Int,
        wakeUpCheckDisableSnoozeOnReAlert: Bool,
        useDefaultSharedSettings: Bool,
        customSharedSettings: SharedAlarmSettings,
        nextTriggerOverrideDate: Date?,
        isEnabled: Bool,
        skipNextUntilDate: Date?,
        snoozeCount: Int,
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
        self.wakeUpCheckEnabled = wakeUpCheckEnabled
        self.wakeUpCheckDelayMinutes = max(1, wakeUpCheckDelayMinutes)
        self.wakeUpCheckDisableSnoozeOnReAlert = wakeUpCheckDisableSnoozeOnReAlert
        self.useDefaultSharedSettings = useDefaultSharedSettings
        self.customSharedSettings = customSharedSettings
        self.nextTriggerOverrideDate = nextTriggerOverrideDate
        self.isEnabled = isEnabled
        self.skipNextUntilDate = skipNextUntilDate
        self.snoozeCount = snoozeCount
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

    var schedule: Alarm.Schedule {
        if let nextTriggerOverrideDate {
            return .fixed(nextTriggerOverrideDate)
        }

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
        case wakeUpCheckEnabled
        case wakeUpCheckDelayMinutes
        case wakeUpCheckDisableSnoozeOnReAlert
        case useDefaultSharedSettings
        case customSharedSettings
        case nextTriggerOverrideDate
        case isEnabled
        case skipNextUntilDate
        case snoozeCount
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
        wakeUpCheckEnabled = try container.decodeIfPresent(Bool.self, forKey: .wakeUpCheckEnabled) ?? false
        wakeUpCheckDelayMinutes = max(1, try container.decodeIfPresent(Int.self, forKey: .wakeUpCheckDelayMinutes) ?? WakeUpCheckDefaults.featureDefaults.delayMinutes)
        wakeUpCheckDisableSnoozeOnReAlert = try container.decodeIfPresent(Bool.self, forKey: .wakeUpCheckDisableSnoozeOnReAlert) ?? WakeUpCheckDefaults.featureDefaults.disableSnoozeOnReAlert

        customSharedSettings = try container.decodeIfPresent(SharedAlarmSettings.self, forKey: .customSharedSettings) ?? .featureDefaults
        useDefaultSharedSettings = try container.decodeIfPresent(Bool.self, forKey: .useDefaultSharedSettings) ?? true
        nextTriggerOverrideDate = try container.decodeIfPresent(Date.self, forKey: .nextTriggerOverrideDate)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        skipNextUntilDate = try container.decodeIfPresent(Date.self, forKey: .skipNextUntilDate)

        snoozeCount = try container.decodeIfPresent(Int.self, forKey: .snoozeCount) ?? 0

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
        try container.encode(wakeUpCheckEnabled, forKey: .wakeUpCheckEnabled)
        try container.encode(wakeUpCheckDelayMinutes, forKey: .wakeUpCheckDelayMinutes)
        try container.encode(wakeUpCheckDisableSnoozeOnReAlert, forKey: .wakeUpCheckDisableSnoozeOnReAlert)
        try container.encode(useDefaultSharedSettings, forKey: .useDefaultSharedSettings)
        try container.encode(customSharedSettings, forKey: .customSharedSettings)
        try container.encodeIfPresent(nextTriggerOverrideDate, forKey: .nextTriggerOverrideDate)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(skipNextUntilDate, forKey: .skipNextUntilDate)
        try container.encode(snoozeCount, forKey: .snoozeCount)
        try container.encode(lifecycleState, forKey: .lifecycleState)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

struct NapAlarmSession: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var durationMinutes: Int
    var targetDate: Date
    var pausedRemainingSeconds: TimeInterval?
    var useDefaultSharedSettings: Bool
    var customSharedSettings: SharedAlarmSettings
    var snoozeCount: Int
    var createdAt: Date
    var updatedAt: Date

    var isPaused: Bool {
        pausedRemainingSeconds != nil
    }

    func resolvedSharedSettings(defaults: SharedAlarmSettings) -> SharedAlarmSettings {
        useDefaultSharedSettings ? defaults : customSharedSettings
    }

    func remainingSeconds(referenceDate: Date = .now) -> TimeInterval {
        if let pausedRemainingSeconds {
            return max(0, pausedRemainingSeconds)
        }

        return max(0, targetDate.timeIntervalSince(referenceDate))
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
    var wakeUpCheckEnabled: Bool
    var wakeUpCheckDelayMinutes: Int
    var wakeUpCheckDisableSnoozeOnReAlert: Bool

    var useDefaultSharedSettings: Bool
    var customSharedSettings: SharedAlarmSettings

    init(
        name: String = "",
        time: Date = .now,
        repeatDays: Set<AlarmWeekday> = [],
        deleteAfterUse: Bool = true,
        wakeUpCheckEnabled: Bool = false,
        wakeUpCheckDelayMinutes: Int = WakeUpCheckDefaults.featureDefaults.delayMinutes,
        wakeUpCheckDisableSnoozeOnReAlert: Bool = WakeUpCheckDefaults.featureDefaults.disableSnoozeOnReAlert,
        useDefaultSharedSettings: Bool = true,
        customSharedSettings: SharedAlarmSettings = .featureDefaults
    ) {
        self.name = name
        self.time = time
        self.repeatDays = repeatDays
        self.deleteAfterUse = deleteAfterUse
        self.wakeUpCheckEnabled = wakeUpCheckEnabled
        self.wakeUpCheckDelayMinutes = max(1, wakeUpCheckDelayMinutes)
        self.wakeUpCheckDisableSnoozeOnReAlert = wakeUpCheckDisableSnoozeOnReAlert
        self.useDefaultSharedSettings = useDefaultSharedSettings
        self.customSharedSettings = customSharedSettings
    }

    init(alarm: UserAlarm) {
        self.name = alarm.name
        self.time = alarm.triggerDateForDisplay
        self.repeatDays = Set(alarm.repeatDays)
        self.deleteAfterUse = alarm.deleteAfterUse
        self.wakeUpCheckEnabled = alarm.wakeUpCheckEnabled
        self.wakeUpCheckDelayMinutes = alarm.wakeUpCheckDelayMinutes
        self.wakeUpCheckDisableSnoozeOnReAlert = alarm.wakeUpCheckDisableSnoozeOnReAlert
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
        existingNextTriggerOverrideDate: Date? = nil,
        existingIsEnabled: Bool = true,
        existingSkipNextUntilDate: Date? = nil,
        existingSnoozeCount: Int?
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
            wakeUpCheckEnabled: wakeUpCheckEnabled,
            wakeUpCheckDelayMinutes: wakeUpCheckDelayMinutes,
            wakeUpCheckDisableSnoozeOnReAlert: wakeUpCheckDisableSnoozeOnReAlert,
            useDefaultSharedSettings: useDefaultSharedSettings,
            customSharedSettings: persistedCustomSharedSettings,
            nextTriggerOverrideDate: existingNextTriggerOverrideDate,
            isEnabled: existingIsEnabled,
            skipNextUntilDate: existingSkipNextUntilDate,
            snoozeCount: existingSnoozeCount ?? 0,
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
