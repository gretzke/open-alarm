import Foundation

// MARK: - Alarm Definition

struct AlarmDefinition: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var trigger: AlarmTrigger
    var recurrence: AlarmRecurrence
    var type: AlarmDefinitionType
    var deleteAfterUse: Bool
    var settingsMode: SettingsMode
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "",
        trigger: AlarmTrigger,
        recurrence: AlarmRecurrence = .none,
        type: AlarmDefinitionType = .regular,
        deleteAfterUse: Bool = true,
        settingsMode: SettingsMode = .useDefault,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trigger = trigger
        self.recurrence = recurrence
        self.type = type
        self.deleteAfterUse = deleteAfterUse
        self.settingsMode = settingsMode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isRepeating: Bool {
        if case .weekly(let days) = recurrence, !days.isEmpty {
            return true
        }
        return false
    }

    var isNap: Bool {
        if case .nap = type { return true }
        return false
    }

    var isTryOut: Bool {
        if case .tryOut = type { return true }
        return false
    }

    var typeKey: AlarmTypeKey {
        switch type {
        case .regular: .regular
        case .nap: .nap
        case .tryOut: .tryOut
        }
    }

    var displayHour: Int {
        switch trigger {
        case .time(let hour, _): return hour
        case .fixed(let date):
            return Calendar.autoupdatingCurrent.component(.hour, from: date)
        }
    }

    var displayMinute: Int {
        switch trigger {
        case .time(_, let minute): return minute
        case .fixed(let date):
            return Calendar.autoupdatingCurrent.component(.minute, from: date)
        }
    }
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

// MARK: - Definition Type (scheduling engine type, distinct from UI AlarmType)

enum AlarmDefinitionType: Codable, Equatable, Sendable {
    case regular
    case nap(NapConfig)
    case tryOut
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
