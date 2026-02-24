import Foundation

struct ShadowTrialAlarm: Codable, Equatable, Sendable {
    var id: UUID
    var snoozeEnabled: Bool
    var snoozeDurationMinutes: Int
    var maxSnoozes: Int?
    var snoozeCount: Int
    var wakeUpCheckEnabled: Bool
    var lifecycleState: AlarmLifecycleState
    var createdAt: Date
    var updatedAt: Date
}

enum AlarmPersistence {
    static let userAlarmsKey = "OPENALARM_USER_ALARMS_V1"
    static let shadowTrialsKey = "OPENALARM_SHADOW_TRIALS_V1"

    static func loadUserAlarms(from defaults: UserDefaults = .standard) -> [UserAlarm] {
        guard let data = defaults.data(forKey: userAlarmsKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([UserAlarm].self, from: data)
        } catch {
            return []
        }
    }

    static func saveUserAlarms(_ alarms: [UserAlarm], to defaults: UserDefaults = .standard) {
        do {
            let data = try JSONEncoder().encode(alarms)
            defaults.set(data, forKey: userAlarmsKey)
        } catch {
            defaults.removeObject(forKey: userAlarmsKey)
        }
    }

    static func loadShadowTrials(from defaults: UserDefaults = .standard) -> [ShadowTrialAlarm] {
        guard let data = defaults.data(forKey: shadowTrialsKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([ShadowTrialAlarm].self, from: data)
        } catch {
            return []
        }
    }

    static func saveShadowTrials(_ trials: [ShadowTrialAlarm], to defaults: UserDefaults = .standard) {
        do {
            let data = try JSONEncoder().encode(trials)
            defaults.set(data, forKey: shadowTrialsKey)
        } catch {
            defaults.removeObject(forKey: shadowTrialsKey)
        }
    }
}
