import AlarmKit
import Foundation
import os

@MainActor
final class ForceCloseAlarmManager {
    private static let logger = Logger(subsystem: "com.openalarm", category: "ForceCloseAlarm")

    private let alarmManager: AlarmManager
    private var timer: Timer?
    private var currentForceCloseAlarmID: UUID?
    private let mainAlarm: AlarmDefinition
    private let resolvedSettings: SharedAlarmSettings

    private static let forceCloseAlarmIDKey = OpenAlarmSharedDefaults.Key.forceCloseAlarmID

    init(
        alarm: AlarmDefinition,
        resolvedSettings: SharedAlarmSettings,
        alarmManager: AlarmManager = .shared
    ) {
        self.mainAlarm = alarm
        self.resolvedSettings = resolvedSettings
        self.alarmManager = alarmManager
    }

    func start() {
        scheduleNextForceCloseAlarm()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleNextForceCloseAlarm()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancelCurrentForceCloseAlarm()
    }

    private func scheduleNextForceCloseAlarm() {
        let newID = UUID()
        let fireDate = Date.now.addingTimeInterval(20)
        let config = AlarmConfigurationBuilder.makeForceCloseAlarmConfiguration(
            for: mainAlarm,
            fireAt: fireDate,
            resolvedSettings: resolvedSettings
        )

        Task {
            _ = try? await alarmManager.schedule(id: newID, configuration: config)

            // Cancel previous after new one is scheduled (no gap)
            if let previousID = currentForceCloseAlarmID {
                try? alarmManager.stop(id: previousID)
                try? alarmManager.cancel(id: previousID)
            }

            currentForceCloseAlarmID = newID
            OpenAlarmSharedDefaults.userDefaults.set(newID.uuidString, forKey: Self.forceCloseAlarmIDKey)
        }
    }

    private func cancelCurrentForceCloseAlarm() {
        if let id = currentForceCloseAlarmID {
            try? alarmManager.stop(id: id)
            try? alarmManager.cancel(id: id)
        }
        currentForceCloseAlarmID = nil
        OpenAlarmSharedDefaults.userDefaults.removeObject(forKey: Self.forceCloseAlarmIDKey)
    }

    static func loadPersistedForceCloseAlarmID() -> UUID? {
        guard let str = OpenAlarmSharedDefaults.userDefaults.string(forKey: forceCloseAlarmIDKey) else { return nil }
        return UUID(uuidString: str)
    }
}
