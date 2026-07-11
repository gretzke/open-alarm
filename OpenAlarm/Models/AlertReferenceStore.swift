import Foundation

struct AlertReference: Codable, Equatable, Sendable {
    let expectedFireDate: Date
    let ringtoneID: String
}

/// Each reference lives under its own defaults key. The app and the Live Activity
/// extension write concurrently from separate processes; per-ID keys make every
/// record/clear an independent atomic write, so writers can't clobber each other
/// the way a shared read-modify-write dictionary would.
struct AlertReferenceStore {
    private static let keyPrefix = OpenAlarmSharedDefaults.Key.alertReferencePrefix

    private let defaults: UserDefaults

    init(defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults) {
        self.defaults = defaults
    }

    func record(_ reference: AlertReference, alarmKitID: UUID) {
        defaults.set(try? JSONEncoder().encode(reference), forKey: Self.key(for: alarmKitID))
    }

    func reference(alarmKitID: UUID) -> AlertReference? {
        guard let data = defaults.data(forKey: Self.key(for: alarmKitID)) else { return nil }
        return try? JSONDecoder().decode(AlertReference.self, from: data)
    }

    func clear(alarmKitID: UUID) {
        defaults.removeObject(forKey: Self.key(for: alarmKitID))
    }

    func sweep(keeping activeIDs: Set<UUID>) {
        let keptKeys = Set(activeIDs.map(Self.key(for:)))
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(Self.keyPrefix) && !keptKeys.contains(key) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func key(for alarmKitID: UUID) -> String {
        keyPrefix + alarmKitID.uuidString
    }
}

enum AlertReferenceResolver {
    static func alertStartedAt(
        recorded: AlertReference?,
        alarmHour: Int,
        alarmMinute: Int,
        now: Date,
        calendar: Calendar
    ) -> Date {
        if let recorded,
           recorded.expectedFireDate <= now,
           now.timeIntervalSince(recorded.expectedFireDate) <= 6 * 60 * 60 {
            return recorded.expectedFireDate
        }

        guard (0...23).contains(alarmHour), (0...59).contains(alarmMinute),
              let today = calendar.date(
                bySettingHour: alarmHour,
                minute: alarmMinute,
                second: 0,
                of: now,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
              ) else {
            return now
        }

        if today <= now {
            return today
        }
        return calendar.date(byAdding: .day, value: -1, to: today) ?? now
    }
}
