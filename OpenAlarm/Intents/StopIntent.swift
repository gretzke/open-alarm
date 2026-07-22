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

        // Single model snapshot for both resolution and the unresolved-cancel
        // guard: two reads could disagree across a concurrent full-blob write
        // and cancel a registration the newer snapshot owns.
        let modelAlarms = persistence.loadUserAlarms()
        let alertReferenceStore = AlertReferenceStore()

        if let resolved = Self.resolveParentAlarm(
            for: id,
            in: modelAlarms,
            persistence: persistence,
            alertReferenceStore: alertReferenceStore
        ) {
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
                    replacing: previous,
                    intentID: id,
                    persistence: persistence
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
            // This is a genuine model-and-registry double miss. Backstop
            // configurations carry the parent UUID, not always the ringing
            // registration's ID; D-3 torn reads hiding both remain accepted.
            // This is event-driven single-ID cleanup, never an AlarmKit sweep.
            if StopIntentPolicy.shouldCancelUnresolved(alarms: modelAlarms) {
                try? AlarmManager.shared.cancel(id: id)
                IntentDiagnostics.log("StopIntent resolved parent=unresolved id=\(id.uuidString) cancel attempted")
            } else {
                IntentDiagnostics.log("StopIntent resolved parent=unresolved id=\(id.uuidString) cancel skipped model=empty")
            }
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

    struct ResolvedAlarm {
        var alarm: AlarmDefinition
        var settings: SharedAlarmSettings
    }

    static func resolveParentAlarm(
        for alarmKitID: UUID,
        in alarms: [AlarmDefinition],
        persistence: AlarmPersistence,
        alertReferenceStore: AlertReferenceStore = AlertReferenceStore()
    ) -> ResolvedAlarm? {
        let index = alarms.firstIndex { alarm in
            alarm.id == alarmKitID
        } ?? alarms.firstIndex { alarm in
            alarm.activeOverride?.bridgeAlarmIDs.contains(alarmKitID) == true
        }
        if let index {
            return resolvedAlarm(for: alarms[index], persistence: persistence)
        }
        guard let parentAlarmID = alertReferenceStore.reference(alarmKitID: alarmKitID)?.parentAlarmID,
              let parentIndex = alarms.firstIndex(where: { $0.id == parentAlarmID }) else {
            return nil
        }
        return resolvedAlarm(for: alarms[parentIndex], persistence: persistence)
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

    @MainActor
    static func scheduleDisarmBackstop(
        for alarm: AlarmDefinition,
        settings: SharedAlarmSettings,
        replacing previousBackstopID: UUID?,
        intentID: UUID,
        persistence: AlarmPersistence,
        alarmManager: any AlarmManagerScheduling = AlarmManager.shared,
        defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults
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
            AlertReferenceStore(defaults: defaults).record(
                AlertReference(
                    expectedFireDate: fireDate,
                    ringtoneID: RingtoneCatalog.resolve(settings.ringtoneID).id,
                    // This overwrites the parent-keyed registration by design; the
                    // parent mapping remains identical while alertStartedAt updates.
                    parentAlarmID: alarm.id
                ),
                alarmKitID: alarm.id
            )
            _ = try await alarmManager.schedule(id: newID, configuration: config)
        } catch {
            IntentDiagnostics.log("StopIntent backstop schedule retry id=\(newID.uuidString) parent=\(alarm.id.uuidString) error=\(error.localizedDescription)")
            try? alarmManager.stop(id: newID)
            try? alarmManager.cancel(id: newID)
            do {
                AlertReferenceStore(defaults: defaults).record(
                    AlertReference(
                        expectedFireDate: fireDate,
                        ringtoneID: RingtoneCatalog.resolve(settings.ringtoneID).id,
                        // Preserve the same parent mapping on the retry overwrite.
                        parentAlarmID: alarm.id
                    ),
                    alarmKitID: alarm.id
                )
                _ = try await alarmManager.schedule(id: newID, configuration: config)
            } catch {
                IntentDiagnostics.log("StopIntent backstop schedule failed id=\(newID.uuidString) parent=\(alarm.id.uuidString) error=\(error.localizedDescription)")
                return
            }
        }

        IntentDiagnostics.log("StopIntent backstop schedule success id=\(newID.uuidString) parent=\(alarm.id.uuidString)")
        BackstopSlotStore.set(backstopID: newID, forParent: alarm.id, defaults: defaults)

        if let previousBackstopID {
            try? alarmManager.stop(id: previousBackstopID)
            try? alarmManager.cancel(id: previousBackstopID)
            IntentDiagnostics.log("StopIntent backstop previous cancelled id=\(previousBackstopID.uuidString) parent=\(alarm.id.uuidString)")
        }

        // The schedule call above suspends with no cycle guard: the challenge
        // can complete while it is in flight, and this write would then park a
        // live 30s backstop in the slot that the wake-check sweep deliberately
        // preserves. Re-check pending-disarm AFTER the slot write (completion
        // removes it before its own slot revocation, so one side always sees
        // the other) and revoke our own write if the cycle already ended.
        let pendingAfterWrite = persistence.loadPendingDisarmAlarmIDs()
        let parentStillPending = pendingAfterWrite.contains(intentID)
            || pendingAfterWrite.contains(alarm.id)
        if !parentStillPending {
            if BackstopSlotStore.backstopID(forParent: alarm.id, defaults: defaults) == newID {
                BackstopSlotStore.clear(forParent: alarm.id, defaults: defaults)
            }
            try? alarmManager.stop(id: newID)
            try? alarmManager.cancel(id: newID)
            IntentDiagnostics.log("StopIntent backstop revoked after late write id=\(newID.uuidString) parent=\(alarm.id.uuidString) reason=cycle-ended")
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
