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
}

struct AlarmDraft: Equatable {
    var time: Date
    var repeatDays: Set<AlarmWeekday>
    var deleteAfterUse: Bool
    var wakeUpCheckEnabled: Bool

    init(time: Date = .now, repeatDays: Set<AlarmWeekday> = [], deleteAfterUse: Bool = true, wakeUpCheckEnabled: Bool = false) {
        self.time = time
        self.repeatDays = repeatDays
        self.deleteAfterUse = deleteAfterUse
        self.wakeUpCheckEnabled = wakeUpCheckEnabled
    }

    init(alarm: UserAlarm) {
        self.time = alarm.triggerDateForDisplay
        self.repeatDays = Set(alarm.repeatDays)
        self.deleteAfterUse = alarm.deleteAfterUse
        self.wakeUpCheckEnabled = alarm.wakeUpCheckEnabled
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
