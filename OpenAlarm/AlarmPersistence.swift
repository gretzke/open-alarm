import Foundation

struct ShadowTrialAlarm: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var snoozeEnabled: Bool
    var snoozeDurationMinutes: Int
    var maxSnoozes: Int?
    var snoozeCount: Int
    var wakeUpCheckEnabled: Bool
    var lifecycleState: AlarmLifecycleState
    var createdAt: Date
    var updatedAt: Date

    var canSnoozeAgain: Bool {
        guard snoozeEnabled else {
            return false
        }
        guard let maxSnoozes else {
            return true
        }
        return snoozeCount < maxSnoozes
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case snoozeEnabled
        case snoozeDurationMinutes
        case maxSnoozes
        case snoozeCount
        case wakeUpCheckEnabled
        case lifecycleState
        case createdAt
        case updatedAt
    }

    init(
        id: UUID,
        name: String,
        snoozeEnabled: Bool,
        snoozeDurationMinutes: Int,
        maxSnoozes: Int?,
        snoozeCount: Int,
        wakeUpCheckEnabled: Bool,
        lifecycleState: AlarmLifecycleState,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.snoozeEnabled = snoozeEnabled
        self.snoozeDurationMinutes = snoozeDurationMinutes
        self.maxSnoozes = maxSnoozes
        self.snoozeCount = snoozeCount
        self.wakeUpCheckEnabled = wakeUpCheckEnabled
        self.lifecycleState = lifecycleState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = (try container.decodeIfPresent(String.self, forKey: .name) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        snoozeEnabled = try container.decodeIfPresent(Bool.self, forKey: .snoozeEnabled) ?? true
        snoozeDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .snoozeDurationMinutes) ?? 5
        maxSnoozes = try container.decodeIfPresent(Int.self, forKey: .maxSnoozes) ?? 3
        snoozeCount = try container.decodeIfPresent(Int.self, forKey: .snoozeCount) ?? 0
        wakeUpCheckEnabled = try container.decodeIfPresent(Bool.self, forKey: .wakeUpCheckEnabled) ?? false
        lifecycleState = try container.decodeIfPresent(AlarmLifecycleState.self, forKey: .lifecycleState) ?? .scheduled
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    }
}

enum AlarmPersistence {
    static let userAlarmsKey = "OPENALARM_USER_ALARMS_V1"
    static let shadowTrialsKey = "OPENALARM_SHADOW_TRIALS_V1"
    static let pendingSnoozeIDsKey = "OPENALARM_PENDING_SNOOZE_IDS_V1"

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
}
