import AlarmKit
import AppIntents
import Foundation
import UserNotifications

struct StopIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent_stop_title"
    static var description = IntentDescription("intent_stop_description")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "alarmID")
    var alarmID: String

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    init() {
        self.alarmID = ""
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else {
            IntentDiagnostics.log("StopIntent entry id=\(alarmID) case=invalid")
            return .result()
        }

        IntentDiagnostics.log("StopIntent entry id=\(id.uuidString)")

        let persistence = AlarmPersistence(defaults: OpenAlarmSharedDefaults.userDefaults)

        // Mark as pending disarm FIRST (tiny write, near-instant).
        // The app handles all lifecycle logic when it opens.
        var pendingDisarm = persistence.loadPendingDisarmAlarmIDs()
        pendingDisarm.insert(id)
        persistence.savePendingDisarmAlarmIDs(pendingDisarm)

        // Silence the alarm
        try? AlarmManager.shared.stop(id: id)

        if let resolved = Self.resolveParentAlarm(for: id, persistence: persistence) {
            let parentID = resolved.alarm.id
            let previous = BackstopSlotStore.backstopID(forParent: parentID)
            // Snapshot once: the toggle is mutable shared state, and the log must
            // describe the same value the protection decision used.
            let effectiveTaskCount = persistence.effectiveTasks(from: resolved.settings).count
            let needsProtection = effectiveTaskCount > 0 || resolved.settings.wakeUpCheckEnabled
            IntentDiagnostics.log("StopIntent resolved parent=\(parentID.uuidString) tasks=\(effectiveTaskCount) wakeCheck=\(resolved.settings.wakeUpCheckEnabled) protect=\(needsProtection)")

            if needsProtection {
                await Self.scheduleDisarmBackstop(
                    for: resolved.alarm,
                    settings: resolved.settings,
                    replacing: previous
                )
            } else {
                if let backstopID = BackstopSlotStore.clear(forParent: parentID) {
                    try? AlarmManager.shared.stop(id: backstopID)
                    try? AlarmManager.shared.cancel(id: backstopID)
                    IntentDiagnostics.log("StopIntent backstop cleared parent=\(parentID.uuidString) id=\(backstopID.uuidString) reason=no-protection")
                }
            }
        } else {
            pendingDisarm.remove(id)
            persistence.savePendingDisarmAlarmIDs(pendingDisarm)
            IntentDiagnostics.log("StopIntent resolved parent=unresolved id=\(id.uuidString) pending=removed")
        }

        // Notify AlarmStore after backstop persistence/cancellation so any
        // in-process UI work sees the newest per-parent slot state.
        NotificationCenter.default.post(name: .disarmChallengeRequested, object: nil)

        await requestForegroundEscalation(caseName: "unified")
        return .result()
    }

    private func requestForegroundEscalation(caseName: String) async {
        do {
            try await continueInForeground(alwaysConfirm: false)
            IntentDiagnostics.log("StopIntent foreground success case=\(caseName)")
        } catch {
            IntentDiagnostics.log("StopIntent foreground failed case=\(caseName) error=\(error.localizedDescription)")
        }
    }

    private struct ResolvedAlarm {
        var alarm: AlarmDefinition
        var settings: SharedAlarmSettings
    }

    private static func resolveParentAlarm(
        for alarmKitID: UUID,
        persistence: AlarmPersistence
    ) -> ResolvedAlarm? {
        let alarms = persistence.loadUserAlarms()
        let index = alarms.firstIndex { alarm in
            alarm.id == alarmKitID
        } ?? alarms.firstIndex { alarm in
            alarm.activeOverride?.bridgeAlarmIDs.contains(alarmKitID) == true
        }
        guard let index else { return nil }
        return resolvedAlarm(for: alarms[index], persistence: persistence)
    }

    private static func resolvedAlarm(
        for alarm: AlarmDefinition,
        persistence: AlarmPersistence
    ) -> ResolvedAlarm {
        let defaultSharedSettings = persistence.loadDefaultSharedSettings()
        let effectiveDefaults: SharedAlarmSettings = alarm.isNap
            ? (persistence.loadNapDefaultSharedSettings() ?? defaultSharedSettings)
            : defaultSharedSettings
        return ResolvedAlarm(
            alarm: alarm,
            settings: alarm.resolvedSharedSettings(defaults: effectiveDefaults)
        )
    }

    private static func scheduleDisarmBackstop(
        for alarm: AlarmDefinition,
        settings: SharedAlarmSettings,
        replacing previousBackstopID: UUID?
    ) async {
        let newID = UUID()
        let fireDate = Date.now.addingTimeInterval(SchedulingConstants.disarmBackstopSeconds)
        let config = AlarmConfigurationBuilder.makeForceCloseAlarmConfiguration(
            for: alarm,
            fireAt: fireDate,
            resolvedSettings: settings
        )

        IntentDiagnostics.log("StopIntent backstop schedule attempt id=\(newID.uuidString) parent=\(alarm.id.uuidString)")
        do {
            // Keyed by the PARENT id: the backstop's StopIntent carries the parent
            // UUID, so that's the pending-disarm id the reference lookup uses.
            AlertReferenceStore().record(
                AlertReference(
                    expectedFireDate: fireDate,
                    ringtoneID: RingtoneCatalog.resolve(settings.ringtoneID).id
                ),
                alarmKitID: alarm.id
            )
            _ = try await AlarmManager.shared.schedule(id: newID, configuration: config)
        } catch {
            IntentDiagnostics.log("StopIntent backstop schedule retry id=\(newID.uuidString) parent=\(alarm.id.uuidString) error=\(error.localizedDescription)")
            try? AlarmManager.shared.stop(id: newID)
            try? AlarmManager.shared.cancel(id: newID)
            do {
                AlertReferenceStore().record(
                    AlertReference(
                        expectedFireDate: fireDate,
                        ringtoneID: RingtoneCatalog.resolve(settings.ringtoneID).id
                    ),
                    alarmKitID: alarm.id
                )
                _ = try await AlarmManager.shared.schedule(id: newID, configuration: config)
            } catch {
                IntentDiagnostics.log("StopIntent backstop schedule failed id=\(newID.uuidString) parent=\(alarm.id.uuidString) error=\(error.localizedDescription)")
                return
            }
        }

        IntentDiagnostics.log("StopIntent backstop schedule success id=\(newID.uuidString) parent=\(alarm.id.uuidString)")
        BackstopSlotStore.set(backstopID: newID, forParent: alarm.id)

        if let previousBackstopID {
            try? AlarmManager.shared.stop(id: previousBackstopID)
            try? AlarmManager.shared.cancel(id: previousBackstopID)
            IntentDiagnostics.log("StopIntent backstop previous cancelled id=\(previousBackstopID.uuidString) parent=\(alarm.id.uuidString)")
        }
    }

    // MARK: - Grace period helpers (shared key with AlarmStore)

    private static let graceAppliedKey = OpenAlarmSharedDefaults.Key.wakeCheckGraceAppliedIDs

    static func loadGraceAppliedIDs() -> Set<UUID> {
        guard let raw = OpenAlarmSharedDefaults.userDefaults.array(forKey: graceAppliedKey) as? [String] else {
            return []
        }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    static func saveGraceAppliedIDs(_ ids: Set<UUID>) {
        OpenAlarmSharedDefaults.userDefaults.set(ids.map(\.uuidString), forKey: graceAppliedKey)
    }
}
