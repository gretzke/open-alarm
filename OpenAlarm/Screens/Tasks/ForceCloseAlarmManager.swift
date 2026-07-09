import AlarmKit
import Foundation
import os

@MainActor
final class ForceCloseAlarmManager {
    private static let logger = Logger(subsystem: "com.openalarm", category: "ForceCloseAlarm")

    private let alarmManager: AlarmManager
    private var timer: Timer?
    private var currentForceCloseAlarmID: UUID?
    private var generation = 0
    private let mainAlarm: AlarmDefinition
    private let resolvedSettings: SharedAlarmSettings

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
        generation += 1
        timer?.invalidate()
        timer = nil
        cancelCurrentForceCloseAlarm()
    }

    private func scheduleNextForceCloseAlarm() {
        let capturedGeneration = generation
        let newID = UUID()
        let fireDate = Date.now.addingTimeInterval(20)
        let config = AlarmConfigurationBuilder.makeForceCloseAlarmConfiguration(
            for: mainAlarm,
            fireAt: fireDate,
            resolvedSettings: resolvedSettings
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await alarmManager.schedule(id: newID, configuration: config)
            } catch {
                Self.logger.error("Force-close schedule failed for \(newID): \(error.localizedDescription)")
                return
            }

            guard generation == capturedGeneration else {
                try? alarmManager.stop(id: newID)
                try? alarmManager.cancel(id: newID)
                return
            }

            // StopIntent may finish scheduling its locked-context backstop after this UI appeared.
            // Cancel only this alarm's persisted slot before this manager takes ownership.
            if let persistedID = BackstopSlotStore.backstopID(forParent: mainAlarm.id),
               persistedID != currentForceCloseAlarmID,
               persistedID != newID {
                try? alarmManager.stop(id: persistedID)
                try? alarmManager.cancel(id: persistedID)
            }

            // Cancel previous after new one is scheduled (no gap)
            if let previousID = currentForceCloseAlarmID {
                try? alarmManager.stop(id: previousID)
                try? alarmManager.cancel(id: previousID)
            }

            currentForceCloseAlarmID = newID
            BackstopSlotStore.set(backstopID: newID, forParent: mainAlarm.id)
        }
    }

    private func cancelCurrentForceCloseAlarm() {
        let ownID = currentForceCloseAlarmID
        if let id = currentForceCloseAlarmID {
            try? alarmManager.stop(id: id)
            try? alarmManager.cancel(id: id)
        }
        // StopIntent may have persisted another backstop for this parent after this manager started.
        // Cancel it too so challenge completion cannot leave a delayed ring behind.
        if let persistedID = BackstopSlotStore.backstopID(forParent: mainAlarm.id),
           persistedID != ownID {
            try? alarmManager.stop(id: persistedID)
            try? alarmManager.cancel(id: persistedID)
        }
        currentForceCloseAlarmID = nil
        BackstopSlotStore.clear(forParent: mainAlarm.id)
    }
}
