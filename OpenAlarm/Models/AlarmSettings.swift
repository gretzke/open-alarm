import Foundation

// MARK: - Settings

struct AlarmSettings: Codable, Equatable, Sendable {
    var snooze: SnoozeConfig
    var wakeUpCheck: WakeUpCheckConfig
    var sound: SoundConfig
    var tasks: TaskConfig

    static let defaults = AlarmSettings(
        snooze: .defaults,
        wakeUpCheck: .defaults,
        sound: .defaults,
        tasks: .defaults
    )
}

struct SnoozeConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var durationMinutes: Int
    var maxCount: Int?

    static let defaults = SnoozeConfig(enabled: false, durationMinutes: 5, maxCount: 3)

    func canSnoozeAgain(currentCount: Int) -> Bool {
        guard enabled else { return false }
        guard let maxCount else { return true }
        return currentCount < maxCount
    }

    var snoozeInterval: TimeInterval {
        durationMinutes == 0 ? 5 : TimeInterval(durationMinutes * 60)
    }
}

struct WakeUpCheckConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var delayMinutes: Int
    var responseTimeoutMinutes: Int

    static let defaults = WakeUpCheckConfig(
        enabled: false,
        delayMinutes: 5,
        responseTimeoutMinutes: 3
    )
}

struct SoundConfig: Codable, Equatable, Sendable {
    static let defaults = SoundConfig()
}

struct TaskConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var challengeType: ChallengeType

    static let defaults = TaskConfig(enabled: false, challengeType: .dummy)
}

enum ChallengeType: String, Codable, Equatable, Sendable {
    case dummy
}

// MARK: - Settings Mode

enum SettingsMode: Codable, Equatable, Sendable {
    case useDefault
    case custom(AlarmSettings)
}

// MARK: - Type key for settings cascade

enum AlarmTypeKey: String, Codable, CaseIterable, Sendable {
    case regular, nap, tryOut
}

// MARK: - Settings Store

struct AlarmSettingsStore: Codable, Equatable, Sendable {
    var globalDefaults: AlarmSettings
    var typeDefaults: [AlarmTypeKey: SettingsMode]

    static let initial = AlarmSettingsStore(
        globalDefaults: .defaults,
        typeDefaults: [:]
    )

    func resolved(for alarm: AlarmDefinition) -> AlarmSettings {
        if case .custom(let s) = alarm.settingsMode { return s }
        if let typeMode = typeDefaults[alarm.typeKey],
           case .custom(let s) = typeMode { return s }
        return globalDefaults
    }
}
