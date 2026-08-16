import Foundation

enum LastRingtoneStore {
    private static let key = OpenAlarmSharedDefaults.Key.lastRingtoneIDs
    private static let lock = NSLock()

    static func lastRingtoneID(
        forAlarm alarmID: UUID,
        defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadRawRingtoneIDs(defaults: defaults)[alarmID.uuidString]
    }

    static func set(
        _ ringtoneID: String,
        forAlarm alarmID: UUID,
        defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults
    ) {
        lock.lock()
        defer { lock.unlock() }
        var ringtoneIDs = loadRawRingtoneIDs(defaults: defaults)
        ringtoneIDs[alarmID.uuidString] = ringtoneID
        defaults.set(ringtoneIDs, forKey: key)
    }

    static func clear(
        forAlarm alarmID: UUID,
        defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults
    ) {
        lock.lock()
        defer { lock.unlock() }
        var ringtoneIDs = loadRawRingtoneIDs(defaults: defaults)
        ringtoneIDs.removeValue(forKey: alarmID.uuidString)
        defaults.set(ringtoneIDs, forKey: key)
    }

    // Serializes in-process read-modify-writes. Cross-process UserDefaults
    // races remain possible and are tracked with the broader D-3 persistence class.
    private static func loadRawRingtoneIDs(defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
