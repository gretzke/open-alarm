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

struct UserAlarm: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var hour: Int
    var minute: Int
    var repeatDays: [AlarmWeekday]
    var deleteAfterUse: Bool
    var wakeUpCheckEnabled: Bool

    var snoozeEnabled: Bool
    var snoozeDurationMinutes: Int
    var maxSnoozes: Int?
    var snoozeCount: Int

    var lifecycleState: AlarmLifecycleState
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        hour: Int,
        minute: Int,
        repeatDays: [AlarmWeekday],
        deleteAfterUse: Bool,
        wakeUpCheckEnabled: Bool,
        snoozeEnabled: Bool,
        snoozeDurationMinutes: Int,
        maxSnoozes: Int?,
        snoozeCount: Int,
        lifecycleState: AlarmLifecycleState,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.hour = hour
        self.minute = minute
        self.repeatDays = repeatDays.sorted { $0.rawValue < $1.rawValue }
        self.deleteAfterUse = deleteAfterUse
        self.wakeUpCheckEnabled = wakeUpCheckEnabled
        self.snoozeEnabled = snoozeEnabled
        self.snoozeDurationMinutes = snoozeDurationMinutes
        self.maxSnoozes = maxSnoozes
        self.snoozeCount = snoozeCount
        self.lifecycleState = lifecycleState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isRepeating: Bool {
        !repeatDays.isEmpty
    }

    var triggerDateForDisplay: Date {
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
        let time = Alarm.Schedule.Relative.Time(hour: hour, minute: minute)
        if repeatDays.isEmpty {
            return .relative(.init(time: time, repeats: .never))
        }

        return .relative(.init(
            time: time,
            repeats: .weekly(sortedRepeatDays.map(\.localeWeekday))
        ))
    }

    var snoozeSummary: String {
        guard snoozeEnabled else {
            return "Off"
        }

        let duration = "\(snoozeDurationMinutes)m"
        let maxPart: String
        if let maxSnoozes {
            maxPart = "max \(maxSnoozes)"
        } else {
            maxPart = "∞"
        }
        return "\(duration), \(maxPart)"
    }

    // Backward-compatible decoding (older stored alarms may not have snooze fields).
    enum CodingKeys: String, CodingKey {
        case id
        case hour
        case minute
        case repeatDays
        case deleteAfterUse
        case wakeUpCheckEnabled
        case snoozeEnabled
        case snoozeDurationMinutes
        case maxSnoozes
        case snoozeCount
        case lifecycleState
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        hour = try container.decode(Int.self, forKey: .hour)
        minute = try container.decode(Int.self, forKey: .minute)
        repeatDays = (try container.decodeIfPresent([AlarmWeekday].self, forKey: .repeatDays) ?? [])
            .sorted { $0.rawValue < $1.rawValue }
        deleteAfterUse = try container.decodeIfPresent(Bool.self, forKey: .deleteAfterUse) ?? true
        wakeUpCheckEnabled = try container.decodeIfPresent(Bool.self, forKey: .wakeUpCheckEnabled) ?? false

        snoozeEnabled = try container.decodeIfPresent(Bool.self, forKey: .snoozeEnabled) ?? true
        snoozeDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .snoozeDurationMinutes) ?? 5
        maxSnoozes = try container.decodeIfPresent(Int.self, forKey: .maxSnoozes) ?? 3
        snoozeCount = try container.decodeIfPresent(Int.self, forKey: .snoozeCount) ?? 0

        lifecycleState = try container.decodeIfPresent(AlarmLifecycleState.self, forKey: .lifecycleState) ?? .scheduled
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(hour, forKey: .hour)
        try container.encode(minute, forKey: .minute)
        try container.encode(repeatDays, forKey: .repeatDays)
        try container.encode(deleteAfterUse, forKey: .deleteAfterUse)
        try container.encode(wakeUpCheckEnabled, forKey: .wakeUpCheckEnabled)
        try container.encode(snoozeEnabled, forKey: .snoozeEnabled)
        try container.encode(snoozeDurationMinutes, forKey: .snoozeDurationMinutes)
        try container.encodeIfPresent(maxSnoozes, forKey: .maxSnoozes)
        try container.encode(snoozeCount, forKey: .snoozeCount)
        try container.encode(lifecycleState, forKey: .lifecycleState)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

struct AlarmDraft: Equatable {
    var time: Date
    var repeatDays: Set<AlarmWeekday>
    var deleteAfterUse: Bool
    var wakeUpCheckEnabled: Bool

    var snoozeEnabled: Bool
    var snoozeDurationMinutes: Int
    var maxSnoozes: Int?

    init(
        time: Date = .now,
        repeatDays: Set<AlarmWeekday> = [],
        deleteAfterUse: Bool = true,
        wakeUpCheckEnabled: Bool = false,
        snoozeEnabled: Bool = true,
        snoozeDurationMinutes: Int = 5,
        maxSnoozes: Int? = 3
    ) {
        self.time = time
        self.repeatDays = repeatDays
        self.deleteAfterUse = deleteAfterUse
        self.wakeUpCheckEnabled = wakeUpCheckEnabled
        self.snoozeEnabled = snoozeEnabled
        self.snoozeDurationMinutes = snoozeDurationMinutes
        self.maxSnoozes = maxSnoozes
    }

    init(alarm: UserAlarm) {
        self.time = alarm.triggerDateForDisplay
        self.repeatDays = Set(alarm.repeatDays)
        self.deleteAfterUse = alarm.deleteAfterUse
        self.wakeUpCheckEnabled = alarm.wakeUpCheckEnabled
        self.snoozeEnabled = alarm.snoozeEnabled
        self.snoozeDurationMinutes = alarm.snoozeDurationMinutes
        self.maxSnoozes = alarm.maxSnoozes
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

    func toUserAlarm(id: UUID, existingCreatedAt: Date?) -> UserAlarm {
        let timeComponents = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: time)
        let hour = timeComponents.hour ?? 7
        let minute = timeComponents.minute ?? 0

        return UserAlarm(
            id: id,
            hour: hour,
            minute: minute,
            repeatDays: Array(repeatDays),
            deleteAfterUse: deleteAfterUse,
            wakeUpCheckEnabled: wakeUpCheckEnabled,
            snoozeEnabled: snoozeEnabled,
            snoozeDurationMinutes: snoozeDurationMinutes,
            maxSnoozes: maxSnoozes,
            snoozeCount: 0,
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
