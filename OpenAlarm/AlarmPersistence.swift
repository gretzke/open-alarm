import Foundation

enum AlarmPersistence {
    static let userAlarmsKey = "OPENALARM_USER_ALARMS_V1"
    static let pendingSnoozeIDsKey = "OPENALARM_PENDING_SNOOZE_IDS_V1"
    static let pendingWakeUpCheckStartIDsKey = "OPENALARM_PENDING_WAKE_CHECK_START_IDS_V1"
    static let pendingWakeUpCheckConfirmIDsKey = "OPENALARM_PENDING_WAKE_CHECK_CONFIRM_IDS_V1"
    static let defaultSharedSettingsKey = "OPENALARM_DEFAULT_SHARED_SETTINGS_V1"
    static let defaultWakeUpCheckDefaultsKey = "OPENALARM_DEFAULT_WAKE_CHECK_DEFAULTS_V1"
    static let wakeUpCheckSessionsKey = "OPENALARM_WAKE_CHECK_SESSIONS_V1"
    static let testingModeEnabledKey = "OPENALARM_TESTING_MODE_ENABLED_V1"
    static let defaultNapDurationMinutesKey = "OPENALARM_DEFAULT_NAP_DURATION_MINUTES_V1"

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



    static func loadPendingSnoozeIDs(from defaults: UserDefaults = .standard) -> Set<UUID> {
        guard let raw = defaults.array(forKey: pendingSnoozeIDsKey) as? [String] else {
            return []
        }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    static func savePendingSnoozeIDs(_ ids: Set<UUID>, to defaults: UserDefaults = .standard) {
        let raw = ids.map(\.uuidString)
        defaults.set(raw, forKey: pendingSnoozeIDsKey)
    }

    static func loadPendingWakeUpCheckStartIDs(from defaults: UserDefaults = .standard) -> Set<UUID> {
        guard let raw = defaults.array(forKey: pendingWakeUpCheckStartIDsKey) as? [String] else {
            return []
        }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    static func savePendingWakeUpCheckStartIDs(_ ids: Set<UUID>, to defaults: UserDefaults = .standard) {
        let raw = ids.map(\.uuidString)
        defaults.set(raw, forKey: pendingWakeUpCheckStartIDsKey)
    }

    static func loadPendingWakeUpCheckConfirmIDs(from defaults: UserDefaults = .standard) -> Set<UUID> {
        guard let raw = defaults.array(forKey: pendingWakeUpCheckConfirmIDsKey) as? [String] else {
            return []
        }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    static func savePendingWakeUpCheckConfirmIDs(_ ids: Set<UUID>, to defaults: UserDefaults = .standard) {
        let raw = ids.map(\.uuidString)
        defaults.set(raw, forKey: pendingWakeUpCheckConfirmIDsKey)
    }

    static func loadDefaultSharedSettings(from defaults: UserDefaults = .standard) -> SharedAlarmSettings {
        guard let data = defaults.data(forKey: defaultSharedSettingsKey) else {
            return .featureDefaults
        }

        do {
            return try JSONDecoder().decode(SharedAlarmSettings.self, from: data)
        } catch {
            return .featureDefaults
        }
    }

    static func saveDefaultSharedSettings(_ settings: SharedAlarmSettings, to defaults: UserDefaults = .standard) {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: defaultSharedSettingsKey)
        } catch {
            defaults.removeObject(forKey: defaultSharedSettingsKey)
        }
    }

    static func loadLegacyDefaultWakeUpCheckDefaults(from defaults: UserDefaults = .standard) -> WakeUpCheckDefaults? {
        guard let data = defaults.data(forKey: defaultWakeUpCheckDefaultsKey) else {
            return nil
        }

        return try? JSONDecoder().decode(WakeUpCheckDefaults.self, from: data)
    }

    static func clearLegacyDefaultWakeUpCheckDefaults(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultWakeUpCheckDefaultsKey)
    }

    static func loadWakeUpCheckSessions(from defaults: UserDefaults = .standard) -> [WakeUpCheckSessionState] {
        guard let data = defaults.data(forKey: wakeUpCheckSessionsKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([WakeUpCheckSessionState].self, from: data)
        } catch {
            return []
        }
    }

    static func saveWakeUpCheckSessions(_ sessions: [WakeUpCheckSessionState], to defaults: UserDefaults = .standard) {
        do {
            let data = try JSONEncoder().encode(sessions)
            defaults.set(data, forKey: wakeUpCheckSessionsKey)
        } catch {
            defaults.removeObject(forKey: wakeUpCheckSessionsKey)
        }
    }

    static func loadTestingModeEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: testingModeEnabledKey)
    }

    static func saveTestingModeEnabled(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: testingModeEnabledKey)
    }

    static func loadDefaultNapDurationMinutes(from defaults: UserDefaults = .standard) -> Int {
        let raw = defaults.integer(forKey: defaultNapDurationMinutesKey)
        return raw > 0 ? raw : 35
    }

    static func saveDefaultNapDurationMinutes(_ minutes: Int, to defaults: UserDefaults = .standard) {
        defaults.set(max(1, minutes), forKey: defaultNapDurationMinutesKey)
    }
}
