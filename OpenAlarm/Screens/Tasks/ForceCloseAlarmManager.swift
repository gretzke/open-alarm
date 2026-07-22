import AlarmKit
import Foundation
import os

@MainActor
final class ForceCloseAlarmManager {
    private static let logger = Logger(subsystem: "com.openalarm", category: "ForceCloseAlarm")

    private let alarmManager: any AlarmManagerScheduling
    private let defaults: UserDefaults
    private var timer: Timer?
    private var currentForceCloseAlarmID: UUID?
    private var currentFireDate: Date?
    private var generation = 0
    private var isSuspended = false
    private let mainAlarm: AlarmDefinition
    private let resolvedSettings: SharedAlarmSettings
    private static let fireTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(
        alarm: AlarmDefinition,
        resolvedSettings: SharedAlarmSettings,
        alarmManager: any AlarmManagerScheduling = AlarmManager.shared,
        defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults
    ) {
        self.mainAlarm = alarm
        self.resolvedSettings = resolvedSettings
        self.alarmManager = alarmManager
        self.defaults = defaults
    }

    func start(replacingOrphanID: UUID? = nil) {
        IntentDiagnostics.log("ForceClose start parent=\(mainAlarm.id.uuidString)")
        isSuspended = false
        currentForceCloseAlarmID = replacingOrphanID
        currentFireDate = replacingOrphanID.flatMap { _ in
            AlertReferenceStore(defaults: defaults)
                .reference(alarmKitID: mainAlarm.id)?
                .expectedFireDate
        }
        scheduleNextForceCloseAlarm()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleNextForceCloseAlarm()
            }
        }
    }

    func stop() {
        IntentDiagnostics.log("ForceClose stop parent=\(mainAlarm.id.uuidString)")
        isSuspended = true
        generation += 1
        timer?.invalidate()
        timer = nil
        cancelCurrentForceCloseAlarm()
    }

    /// View disappearance is NOT evidence of challenge completion: the scene
    /// teardown of a force-quit runs `onDisappear` while the process is still
    /// alive, and a terminal cancel there destroys the very protection the
    /// backstop exists for. Suspend stops all future scheduling (flag for
    /// queued ticks, generation bump so an in-flight schedule self-cancels via
    /// the stale-generation guard) but deliberately leaves the current
    /// registration and its persisted slot alive. Legitimate completion goes
    /// through `stop()` via `complete()` before dismissal; leftover
    /// registrations are reaped by the next TaskUI appearance's orphan clear
    /// or the app-open sweep.
    func suspend() {
        IntentDiagnostics.log(
            "ForceClose suspend parent=\(mainAlarm.id.uuidString) keepAlive=\(currentForceCloseAlarmID?.uuidString ?? "none")"
        )
        isSuspended = true
        generation += 1
        timer?.invalidate()
        timer = nil
    }

    private func scheduleNextForceCloseAlarm() {
        guard !isSuspended else { return }
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
                // Keyed by the PARENT id: the backstop's StopIntent carries the parent
                // UUID, so that's the pending-disarm id the reference lookup uses.
                AlertReferenceStore(defaults: defaults).record(
                    AlertReference(
                        expectedFireDate: fireDate,
                        ringtoneID: RingtoneCatalog.resolve(resolvedSettings.ringtoneID).id,
                        // Parent-keyed by design; overwrite keeps this mapping
                        // stable while refreshing the backstop fire time.
                        parentAlarmID: mainAlarm.id
                    ),
                    alarmKitID: mainAlarm.id
                )
                IntentDiagnostics.log(
                    "ForceClose schedule attempt id=\(newID.uuidString) parent=\(mainAlarm.id.uuidString) fireAt=\(Self.fireTimeFormatter.string(from: fireDate))"
                )
                _ = try await alarmManager.schedule(id: newID, configuration: config)
                IntentDiagnostics.log(
                    "ForceClose scheduled id=\(newID.uuidString) parent=\(mainAlarm.id.uuidString) fireAt=\(Self.fireTimeFormatter.string(from: fireDate))"
                )
            } catch {
                Self.logger.error("Force-close schedule failed for \(newID): \(error.localizedDescription)")
                IntentDiagnostics.log(
                    "ForceClose schedule FAILED id=\(newID.uuidString) parent=\(mainAlarm.id.uuidString) error=\(error.localizedDescription)"
                )
                restoreCurrentAlertReference()
                return
            }

            guard generation == capturedGeneration else {
                try? alarmManager.stop(id: newID)
                try? alarmManager.cancel(id: newID)
                restoreCurrentAlertReference()
                IntentDiagnostics.log(
                    "ForceClose cancel attempted id=\(newID.uuidString) parent=\(mainAlarm.id.uuidString) reason=stale-generation"
                )
                return
            }

            // StopIntent may finish scheduling its locked-context backstop after this UI appeared.
            // Cancel only this alarm's persisted slot before this manager takes ownership.
            if let persistedID = BackstopSlotStore.backstopID(forParent: mainAlarm.id, defaults: defaults),
               persistedID != currentForceCloseAlarmID,
               persistedID != newID {
                _ = cancelRegistration(id: persistedID)
                IntentDiagnostics.log(
                    "ForceClose cancel attempted id=\(persistedID.uuidString) parent=\(mainAlarm.id.uuidString) reason=slot-takeover"
                )
            }

            // Cancel previous after new one is scheduled (no gap)
            if let previousID = currentForceCloseAlarmID {
                _ = cancelRegistration(id: previousID)
                IntentDiagnostics.log(
                    "ForceClose cancel attempted id=\(previousID.uuidString) parent=\(mainAlarm.id.uuidString) reason=replaced"
                )
            }

            currentForceCloseAlarmID = newID
            currentFireDate = fireDate
            BackstopSlotStore.set(backstopID: newID, forParent: mainAlarm.id, defaults: defaults)
        }
    }

    private func cancelCurrentForceCloseAlarm() {
        let ownID = currentForceCloseAlarmID
        var cancelledIDs = Set<UUID>()
        if let id = ownID {
            if cancelRegistration(id: id) {
                cancelledIDs.insert(id)
            }
            IntentDiagnostics.log(
                "ForceClose cancel attempted id=\(id.uuidString) parent=\(mainAlarm.id.uuidString) reason=challenge-done"
            )
        }
        // StopIntent may have persisted another backstop for this parent after this manager started.
        // Cancel it too so challenge completion cannot leave a delayed ring behind.
        let persistedID = BackstopSlotStore.backstopID(forParent: mainAlarm.id, defaults: defaults)
        if let persistedID, persistedID != ownID {
            if cancelRegistration(id: persistedID) {
                cancelledIDs.insert(persistedID)
            }
            IntentDiagnostics.log(
                "ForceClose cancel attempted id=\(persistedID.uuidString) parent=\(mainAlarm.id.uuidString) reason=challenge-done-slot"
            )
        }
        currentForceCloseAlarmID = nil
        currentFireDate = nil
        if let persistedID, cancelledIDs.contains(persistedID) {
            BackstopSlotStore.clear(forParent: mainAlarm.id, defaults: defaults)
        } else if persistedID == nil {
            BackstopSlotStore.clear(forParent: mainAlarm.id, defaults: defaults)
        }
    }

    private func cancelRegistration(id: UUID) -> Bool {
        func attempt() -> Bool {
            var succeeded = true
            do {
                try alarmManager.stop(id: id)
            } catch {
                succeeded = false
            }
            do {
                try alarmManager.cancel(id: id)
            } catch {
                succeeded = false
            }
            return succeeded
        }

        guard !attempt() else { return true }
        guard !attempt() else { return true }
        IntentDiagnostics.log("ForceClose cancel failed retained id=\(id.uuidString) parent=\(mainAlarm.id.uuidString)")
        return false
    }

    func adoptForTesting(currentID: UUID, fireDate: Date) {
        currentForceCloseAlarmID = currentID
        currentFireDate = fireDate
    }

    func restoreCurrentAlertReference() {
        guard let fireDate = currentFireDate else { return }
        AlertReferenceStore(defaults: defaults).record(
            AlertReference(
                expectedFireDate: fireDate,
                ringtoneID: RingtoneCatalog.resolve(resolvedSettings.ringtoneID).id,
                parentAlarmID: mainAlarm.id
            ),
            alarmKitID: mainAlarm.id
        )
        IntentDiagnostics.log("ForceClose reference restored parent=\(mainAlarm.id.uuidString) fireAt=\(Self.fireTimeFormatter.string(from: fireDate))")
    }
}
