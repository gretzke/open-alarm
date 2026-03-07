import Foundation
import os

final class AlarmPersistenceV2: Sendable {
    private static let logger = Logger(subsystem: "com.openalarm", category: "AlarmPersistenceV2")

    private nonisolated(unsafe) let defaults: UserDefaults

    private let alarmsKey = "OPENALARM_ALARM_DEFINITIONS_V2"
    private let settingsStoreKey = "OPENALARM_SETTINGS_STORE_V2"
    private let pendingEventsKey = "OPENALARM_PENDING_EVENTS_V2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Alarm Definitions

    func loadAlarms() -> [AlarmDefinition] {
        guard let data = defaults.data(forKey: alarmsKey) else { return [] }
        do {
            return try JSONDecoder().decode([AlarmDefinition].self, from: data)
        } catch {
            Self.logger.error("Failed to decode alarms: \(error.localizedDescription)")
            return []
        }
    }

    func saveAlarms(_ alarms: [AlarmDefinition]) {
        do {
            let data = try JSONEncoder().encode(alarms)
            defaults.set(data, forKey: alarmsKey)
        } catch {
            Self.logger.error("Failed to encode alarms: \(error.localizedDescription)")
        }
    }

    // MARK: - Settings Store

    func loadSettingsStore() -> AlarmSettingsStore {
        guard let data = defaults.data(forKey: settingsStoreKey) else {
            return .initial
        }
        do {
            return try JSONDecoder().decode(AlarmSettingsStore.self, from: data)
        } catch {
            Self.logger.error("Failed to decode settings store: \(error.localizedDescription)")
            return .initial
        }
    }

    func saveSettingsStore(_ store: AlarmSettingsStore) {
        do {
            let data = try JSONEncoder().encode(store)
            defaults.set(data, forKey: settingsStoreKey)
        } catch {
            Self.logger.error("Failed to encode settings store: \(error.localizedDescription)")
        }
    }

    // MARK: - Pending Events

    func loadPendingEvents() -> [PendingAlarmEvent] {
        guard let data = defaults.data(forKey: pendingEventsKey) else { return [] }
        do {
            return try JSONDecoder().decode([PendingAlarmEvent].self, from: data)
        } catch {
            Self.logger.error("Failed to decode pending events: \(error.localizedDescription)")
            return []
        }
    }

    func savePendingEvents(_ events: [PendingAlarmEvent]) {
        do {
            let data = try JSONEncoder().encode(events)
            defaults.set(data, forKey: pendingEventsKey)
        } catch {
            Self.logger.error("Failed to encode pending events: \(error.localizedDescription)")
        }
    }

    func enqueuePendingEvent(_ event: PendingAlarmEvent) {
        var events = loadPendingEvents()
        events.append(event)
        savePendingEvents(events)
    }

    func clearPendingEvents(for alarmID: UUID) {
        var events = loadPendingEvents()
        events.removeAll { $0.alarmID == alarmID }
        savePendingEvents(events)
    }
}

struct PendingAlarmEvent: Codable, Equatable, Sendable {
    var alarmID: UUID
    var kind: PendingAlarmEventKind
    var createdAt: Date

    init(alarmID: UUID, kind: PendingAlarmEventKind, createdAt: Date = .now) {
        self.alarmID = alarmID
        self.kind = kind
        self.createdAt = createdAt
    }
}

enum PendingAlarmEventKind: String, Codable, Equatable, Sendable {
    case stopped
    case snoozed
}
