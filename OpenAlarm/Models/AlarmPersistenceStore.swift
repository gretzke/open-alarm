import Foundation
import os

// Foundation-only persistence layer. Compiled in both the app target and the
// OpenAlarmSchedulingCore SPM package — must not import AlarmKit or UIKit.

final class AlarmPersistence: Sendable {
    private static let logger = Logger(subsystem: "com.openalarm", category: "AlarmPersistence")
    private static let appGroupMigrationKey = "OPENALARM_APP_GROUP_STORE_MIGRATED_V1"

    static let shared = AlarmPersistence(defaults: OpenAlarmSharedDefaults.userDefaults)

    private nonisolated(unsafe) let defaults: UserDefaults

    private let userAlarmsKey = "OPENALARM_USER_ALARMS_V1"
    private let defaultSharedSettingsKey = "OPENALARM_DEFAULT_SHARED_SETTINGS_V1"
    private let testingModeEnabledKey = "OPENALARM_TESTING_MODE_ENABLED_V1"
    private let napDefaultSharedSettingsKey = "OPENALARM_NAP_DEFAULT_SHARED_SETTINGS_V1"
    private let defaultNapDurationMinutesKey = "OPENALARM_DEFAULT_NAP_DURATION_MINUTES_V1"
    private let liveActivitiesEnabledKey = "OPENALARM_LIVE_ACTIVITIES_ENABLED_V1"
    private let pendingWakeUpCheckShowConfirmUIIDsKey = "OPENALARM_PENDING_WAKE_CHECK_SHOW_CONFIRM_UI_IDS_V1"
    private let wakeCheckSessionsKey = "OPENALARM_WAKE_CHECK_SESSIONS_V1"
    private let pendingDisarmAlarmIDsKey = "OPENALARM_PENDING_DISARM_ALARM_IDS_V1"
    init(defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults) {
        self.defaults = defaults
    }

    static func migrateStandardStoreIfNeeded() {
        let sharedDefaults = OpenAlarmSharedDefaults.userDefaults
        let standardDefaults = UserDefaults.standard

        guard sharedDefaults !== standardDefaults else {
            return
        }

        guard !sharedDefaults.bool(forKey: appGroupMigrationKey) else {
            return
        }

        let keysToMigrate = [
            "OPENALARM_USER_ALARMS_V1",
            "OPENALARM_DEFAULT_SHARED_SETTINGS_V1",
            "OPENALARM_TESTING_MODE_ENABLED_V1",
            "OPENALARM_NAP_DEFAULT_SHARED_SETTINGS_V1",
            "OPENALARM_DEFAULT_NAP_DURATION_MINUTES_V1",
            "OPENALARM_LIVE_ACTIVITIES_ENABLED_V1",
            "OPENALARM_PENDING_WAKE_CHECK_SHOW_CONFIRM_UI_IDS_V1",
            "OPENALARM_WAKE_CHECK_SESSIONS_V1",
            "OPENALARM_PENDING_DISARM_ALARM_IDS_V1",
            "OPENALARM_FORCE_CLOSE_ALARM_ID",
            "OPENALARM_WAKE_CHECK_GRACE_APPLIED_IDS"
        ]

        for key in keysToMigrate where sharedDefaults.object(forKey: key) == nil {
            if let value = standardDefaults.object(forKey: key) {
                sharedDefaults.set(value, forKey: key)
            }
        }

        sharedDefaults.set(true, forKey: appGroupMigrationKey)
    }

    // MARK: - User Alarms

    static let corruptUserAlarmsKey = "OPENALARM_USER_ALARMS_CORRUPT_V1"

    func loadUserAlarms() -> [UserAlarm] {
        guard let data = defaults.data(forKey: userAlarmsKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([UserAlarm].self, from: data)
        } catch {
            // Never silently destroy the user's alarms: quarantine the corrupt
            // blob for recovery (a follow-up save would otherwise persist [] and
            // make the loss permanent). Keep the first quarantined blob — it is
            // the closest to the last known-good state.
            Self.logger.error("Alarm store decode failed, quarantining blob: \(error.localizedDescription)")
            if defaults.data(forKey: Self.corruptUserAlarmsKey) == nil {
                defaults.set(data, forKey: Self.corruptUserAlarmsKey)
            }
            return []
        }
    }

    func saveUserAlarms(_ alarms: [UserAlarm]) {
        do {
            let data = try JSONEncoder().encode(alarms)
            defaults.set(data, forKey: userAlarmsKey)
        } catch {
            // Never delete the existing (good) data because a new encode failed.
            Self.logger.error("Alarm store encode failed, keeping previous data: \(error.localizedDescription)")
        }
    }

    // MARK: - Default Shared Settings

    func loadDefaultSharedSettings() -> SharedAlarmSettings {
        guard let data = defaults.data(forKey: defaultSharedSettingsKey) else {
            return .featureDefaults
        }

        do {
            return try JSONDecoder().decode(SharedAlarmSettings.self, from: data)
        } catch {
            return .featureDefaults
        }
    }

    func saveDefaultSharedSettings(_ settings: SharedAlarmSettings) {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: defaultSharedSettingsKey)
        } catch {
            defaults.removeObject(forKey: defaultSharedSettingsKey)
        }
    }

    // MARK: - Testing Mode

    func loadTestingModeEnabled() -> Bool {
        defaults.bool(forKey: testingModeEnabledKey)
    }

    func saveTestingModeEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: testingModeEnabledKey)
    }

    // MARK: - Nap Default Shared Settings

    func loadNapDefaultSharedSettings() -> SharedAlarmSettings? {
        guard let data = defaults.data(forKey: napDefaultSharedSettingsKey) else { return nil }
        do {
            return try JSONDecoder().decode(SharedAlarmSettings.self, from: data)
        } catch {
            Self.logger.error("Failed to decode nap default settings: \(error.localizedDescription)")
            return nil
        }
    }

    func saveNapDefaultSharedSettings(_ settings: SharedAlarmSettings?) {
        if let settings {
            do {
                let data = try JSONEncoder().encode(settings)
                defaults.set(data, forKey: napDefaultSharedSettingsKey)
            } catch {
                Self.logger.error("Failed to encode nap default settings: \(error.localizedDescription)")
            }
        } else {
            defaults.removeObject(forKey: napDefaultSharedSettingsKey)
        }
    }

    // MARK: - Default Nap Duration

    func loadDefaultNapDurationMinutes() -> Int {
        // 0 is a valid sentinel for 5-second testing mode naps
        if defaults.object(forKey: defaultNapDurationMinutesKey) == nil {
            return 35
        }
        return defaults.integer(forKey: defaultNapDurationMinutesKey)
    }

    func saveDefaultNapDurationMinutes(_ minutes: Int) {
        defaults.set(max(0, minutes), forKey: defaultNapDurationMinutesKey)
    }

    // MARK: - Live Activity Settings

    func loadLiveActivitiesEnabled() -> Bool {
        if defaults.object(forKey: liveActivitiesEnabledKey) == nil {
            return true
        }
        return defaults.bool(forKey: liveActivitiesEnabledKey)
    }

    func saveLiveActivitiesEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: liveActivitiesEnabledKey)
    }

    // MARK: - Pending Wake-Up Check Show Confirm UI IDs

    func loadPendingWakeUpCheckShowConfirmUIIDs() -> Set<UUID> {
        loadUUIDSet(forKey: pendingWakeUpCheckShowConfirmUIIDsKey)
    }

    func savePendingWakeUpCheckShowConfirmUIIDs(_ ids: Set<UUID>) {
        saveUUIDSet(ids, forKey: pendingWakeUpCheckShowConfirmUIIDsKey)
    }

    // MARK: - Wake Check Sessions

    func loadWakeCheckSessions() -> [UUID: WakeCheckSession] {
        guard let data = defaults.data(forKey: wakeCheckSessionsKey) else { return [:] }
        do {
            let sessions = try JSONDecoder().decode([WakeCheckSession].self, from: data)
            return Dictionary(uniqueKeysWithValues: sessions.map { ($0.alarmID, $0) })
        } catch {
            Self.logger.error("Failed to decode wake check sessions: \(error.localizedDescription)")
            return [:]
        }
    }

    func saveWakeCheckSessions(_ sessions: [UUID: WakeCheckSession]) {
        do {
            let array = Array(sessions.values)
            let data = try JSONEncoder().encode(array)
            defaults.set(data, forKey: wakeCheckSessionsKey)
        } catch {
            Self.logger.error("Failed to encode wake check sessions: \(error.localizedDescription)")
        }
    }

    // MARK: - Pending Disarm Alarm IDs

    func loadPendingDisarmAlarmIDs() -> Set<UUID> {
        loadUUIDSet(forKey: pendingDisarmAlarmIDsKey)
    }

    func savePendingDisarmAlarmIDs(_ ids: Set<UUID>) {
        saveUUIDSet(ids, forKey: pendingDisarmAlarmIDsKey)
    }

    // MARK: - Private helpers

    private func loadUUIDSet(forKey key: String) -> Set<UUID> {
        guard let raw = defaults.array(forKey: key) as? [String] else {
            return []
        }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private func saveUUIDSet(_ ids: Set<UUID>, forKey key: String) {
        let raw = ids.map(\.uuidString)
        defaults.set(raw, forKey: key)
    }
}
