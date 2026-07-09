import Foundation

enum BackstopSlotStore {
    private static let key = OpenAlarmSharedDefaults.Key.backstopSlots
    private static let legacyBackstopIDKey = OpenAlarmSharedDefaults.Key.legacyBackstopAlarmID
    private static let legacyParentIDKey = OpenAlarmSharedDefaults.Key.legacyBackstopParentAlarmID
    private static let lock = NSLock()

    static func backstopID(
        forParent parentID: UUID,
        defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults
    ) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return UUID(uuidString: loadRawSlots(defaults: defaults)[parentID.uuidString] ?? "")
    }

    static func parentID(
        forBackstop backstopID: UUID,
        defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults
    ) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        let backstopString = backstopID.uuidString
        guard let rawParent = loadRawSlots(defaults: defaults).first(where: { $0.value == backstopString })?.key else {
            return nil
        }
        return UUID(uuidString: rawParent)
    }

    static func set(
        backstopID: UUID,
        forParent parentID: UUID,
        defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults
    ) {
        lock.lock()
        defer { lock.unlock() }
        var slots = loadRawSlots(defaults: defaults)
        slots[parentID.uuidString] = backstopID.uuidString
        defaults.set(slots, forKey: key)
    }

    @discardableResult
    static func clear(
        forParent parentID: UUID,
        defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults
    ) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        var slots = loadRawSlots(defaults: defaults)
        let removed = slots.removeValue(forKey: parentID.uuidString).flatMap(UUID.init(uuidString:))
        defaults.set(slots, forKey: key)
        return removed
    }

    static func allSlots(defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults) -> [UUID: UUID] {
        lock.lock()
        defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: loadRawSlots(defaults: defaults).compactMap { parent, backstop in
            guard let parentID = UUID(uuidString: parent),
                  let backstopID = UUID(uuidString: backstop) else {
                return nil
            }
            return (parentID, backstopID)
        })
    }

    static func migrateLegacySlotIfNeeded(defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults) {
        lock.lock()
        defer { lock.unlock() }

        if let backstopString = defaults.string(forKey: legacyBackstopIDKey),
           let parentString = defaults.string(forKey: legacyParentIDKey),
           UUID(uuidString: backstopString) != nil,
           UUID(uuidString: parentString) != nil {
            var slots = loadRawSlots(defaults: defaults)
            slots[parentString] = backstopString
            defaults.set(slots, forKey: key)
        }

        defaults.removeObject(forKey: legacyBackstopIDKey)
        defaults.removeObject(forKey: legacyParentIDKey)
    }

    // Serializes in-process read-modify-writes. Cross-process UserDefaults
    // races remain possible and are tracked with the broader D-3 persistence class.
    private static func loadRawSlots(defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
