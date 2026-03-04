import Foundation
import os

final class AlarmPersistence: Sendable {
    static let shared = AlarmPersistence()

    private static let logger = Logger(subsystem: "com.openalarm", category: "AlarmPersistence")

    private nonisolated(unsafe) let defaults: UserDefaults

    private let userAlarmsKey = "OPENALARM_USER_ALARMS_V1"
    private let pendingSnoozeIDsKey = "OPENALARM_PENDING_SNOOZE_IDS_V1"
    private let pendingWakeUpCheckStartIDsKey = "OPENALARM_PENDING_WAKE_CHECK_START_IDS_V1"
    private let pendingWakeUpCheckConfirmIDsKey = "OPENALARM_PENDING_WAKE_CHECK_CONFIRM_IDS_V1"
    private let defaultSharedSettingsKey = "OPENALARM_DEFAULT_SHARED_SETTINGS_V1"
    private let defaultWakeUpCheckDefaultsKey = "OPENALARM_DEFAULT_WAKE_CHECK_DEFAULTS_V1"
    private let wakeUpCheckSessionsKey = "OPENALARM_WAKE_CHECK_SESSIONS_V1"
    private let testingModeEnabledKey = "OPENALARM_TESTING_MODE_ENABLED_V1"
    private let defaultNapDurationMinutesKey = "OPENALARM_DEFAULT_NAP_DURATION_MINUTES_V1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Pending ID helpers

    enum PendingIDKey {
        case snooze
        case wakeStart
        case wakeConfirm
    }

    /// Removes `id` from the given pending set. Returns `true` if the set was changed.
    @discardableResult
    func removePendingID(_ id: UUID, from key: PendingIDKey) -> Bool {
        var ids = loadPendingIDs(for: key)
        guard ids.remove(id) != nil else {
            return false
        }
        savePendingIDs(ids, for: key)
        return true
    }

    /// Removes `id` from all three pending sets. Returns `true` if any set was changed.
    @discardableResult
    func removePendingIDFromAll(_ id: UUID) -> Bool {
        var changed = false
        for key in [PendingIDKey.snooze, .wakeStart, .wakeConfirm] {
            if removePendingID(id, from: key) {
                changed = true
            }
        }
        return changed
    }

    func loadPendingIDs(for key: PendingIDKey) -> Set<UUID> {
        loadUUIDSet(forKey: defaultsKey(for: key))
    }

    func savePendingIDs(_ ids: Set<UUID>, for key: PendingIDKey) {
        saveUUIDSet(ids, forKey: defaultsKey(for: key))
    }

    // MARK: - User Alarms

    func loadUserAlarms() -> [UserAlarm] {
        guard let data = defaults.data(forKey: userAlarmsKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([UserAlarm].self, from: data)
        } catch {
            Self.logger.error("Failed to decode user alarms: \(error.localizedDescription)")
            return []
        }
    }

    func saveUserAlarms(_ alarms: [UserAlarm]) {
        do {
            let data = try JSONEncoder().encode(alarms)
            defaults.set(data, forKey: userAlarmsKey)
        } catch {
            Self.logger.error("Failed to encode user alarms: \(error.localizedDescription)")
            defaults.removeObject(forKey: userAlarmsKey)
        }
    }

    // MARK: - Pending Snooze IDs

    func loadPendingSnoozeIDs() -> Set<UUID> {
        loadUUIDSet(forKey: pendingSnoozeIDsKey)
    }

    func savePendingSnoozeIDs(_ ids: Set<UUID>) {
        saveUUIDSet(ids, forKey: pendingSnoozeIDsKey)
    }

    // MARK: - Pending Wake-Up Check Start IDs

    func loadPendingWakeUpCheckStartIDs() -> Set<UUID> {
        loadUUIDSet(forKey: pendingWakeUpCheckStartIDsKey)
    }

    func savePendingWakeUpCheckStartIDs(_ ids: Set<UUID>) {
        saveUUIDSet(ids, forKey: pendingWakeUpCheckStartIDsKey)
    }

    // MARK: - Pending Wake-Up Check Confirm IDs

    func loadPendingWakeUpCheckConfirmIDs() -> Set<UUID> {
        loadUUIDSet(forKey: pendingWakeUpCheckConfirmIDsKey)
    }

    func savePendingWakeUpCheckConfirmIDs(_ ids: Set<UUID>) {
        saveUUIDSet(ids, forKey: pendingWakeUpCheckConfirmIDsKey)
    }

    // MARK: - Default Shared Settings

    func loadDefaultSharedSettings() -> SharedAlarmSettings {
        guard let data = defaults.data(forKey: defaultSharedSettingsKey) else {
            return .featureDefaults
        }

        do {
            return try JSONDecoder().decode(SharedAlarmSettings.self, from: data)
        } catch {
            Self.logger.error("Failed to decode default shared settings: \(error.localizedDescription)")
            return .featureDefaults
        }
    }

    func saveDefaultSharedSettings(_ settings: SharedAlarmSettings) {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: defaultSharedSettingsKey)
        } catch {
            Self.logger.error("Failed to encode default shared settings: \(error.localizedDescription)")
            defaults.removeObject(forKey: defaultSharedSettingsKey)
        }
    }

    // MARK: - Legacy Wake-Up Check Defaults

    func loadLegacyDefaultWakeUpCheckDefaults() -> WakeUpCheckDefaults? {
        guard let data = defaults.data(forKey: defaultWakeUpCheckDefaultsKey) else {
            return nil
        }

        do {
            return try JSONDecoder().decode(WakeUpCheckDefaults.self, from: data)
        } catch {
            Self.logger.error("Failed to decode legacy wake-up check defaults: \(error.localizedDescription)")
            return nil
        }
    }

    func clearLegacyDefaultWakeUpCheckDefaults() {
        defaults.removeObject(forKey: defaultWakeUpCheckDefaultsKey)
    }

    // MARK: - Wake-Up Check Sessions

    func loadWakeUpCheckSessions() -> [WakeUpCheckSessionState] {
        guard let data = defaults.data(forKey: wakeUpCheckSessionsKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([WakeUpCheckSessionState].self, from: data)
        } catch {
            Self.logger.error("Failed to decode wake-up check sessions: \(error.localizedDescription)")
            return []
        }
    }

    func saveWakeUpCheckSessions(_ sessions: [WakeUpCheckSessionState]) {
        do {
            let data = try JSONEncoder().encode(sessions)
            defaults.set(data, forKey: wakeUpCheckSessionsKey)
        } catch {
            Self.logger.error("Failed to encode wake-up check sessions: \(error.localizedDescription)")
            defaults.removeObject(forKey: wakeUpCheckSessionsKey)
        }
    }

    // MARK: - Testing Mode

    func loadTestingModeEnabled() -> Bool {
        defaults.bool(forKey: testingModeEnabledKey)
    }

    func saveTestingModeEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: testingModeEnabledKey)
    }

    // MARK: - Default Nap Duration

    func loadDefaultNapDurationMinutes() -> Int {
        let raw = defaults.integer(forKey: defaultNapDurationMinutesKey)
        return raw > 0 ? raw : 35
    }

    func saveDefaultNapDurationMinutes(_ minutes: Int) {
        defaults.set(max(1, minutes), forKey: defaultNapDurationMinutesKey)
    }

    // MARK: - Private helpers

    private func defaultsKey(for key: PendingIDKey) -> String {
        switch key {
        case .snooze: pendingSnoozeIDsKey
        case .wakeStart: pendingWakeUpCheckStartIDsKey
        case .wakeConfirm: pendingWakeUpCheckConfirmIDsKey
        }
    }

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
