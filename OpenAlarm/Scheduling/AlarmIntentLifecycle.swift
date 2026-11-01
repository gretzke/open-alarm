import Foundation

enum AlarmIntentLifecycle {
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
        alarmManager: any AlarmManagerScheduling,
        defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults
    ) async {
        let newID = UUID()
        let fireDate = Date.now.addingTimeInterval(SchedulingConstants.disarmBackstopSeconds)
        let ringtoneID = RingtoneCatalog.resolve(
            AlertReferenceStore(defaults: defaults).reference(alarmKitID: intentID)?.ringtoneID
                ?? LastRingtoneStore.lastRingtoneID(forAlarm: alarm.id, defaults: defaults)
                ?? settings.ringtoneID
        ).id
        let config = AlarmSchedulingRequest.makeForceCloseAlarmConfiguration(
            for: alarm,
            fireAt: fireDate,
            resolvedSettings: settings,
            ringtoneID: ringtoneID
        )

        IntentDiagnostics.log("StopIntent backstop schedule attempt id=\(newID.uuidString) parent=\(alarm.id.uuidString)")
        do {
            // Keyed by the PARENT id: the backstop's StopIntent carries the parent
            // UUID, so that's the pending-disarm id the reference lookup uses.
            AlertReferenceStore(defaults: defaults).record(
                AlertReference(
                    expectedFireDate: fireDate,
                    ringtoneID: ringtoneID,
                    // This overwrites the parent-keyed registration by design; the
                    // parent mapping remains identical while alertStartedAt updates.
                    parentAlarmID: alarm.id
                ),
                alarmKitID: alarm.id
            )
            try await alarmManager.schedule(id: newID, configuration: config)
        } catch {
            IntentDiagnostics.log("StopIntent backstop schedule retry id=\(newID.uuidString) parent=\(alarm.id.uuidString) error=\(error.localizedDescription)")
            try? alarmManager.stop(id: newID)
            try? alarmManager.cancel(id: newID)
            do {
                AlertReferenceStore(defaults: defaults).record(
                    AlertReference(
                        expectedFireDate: fireDate,
                        ringtoneID: ringtoneID,
                        // Preserve the same parent mapping on the retry overwrite.
                        parentAlarmID: alarm.id
                    ),
                    alarmKitID: alarm.id
                )
                try await alarmManager.schedule(id: newID, configuration: config)
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

    static func loadGraceAppliedIDs(defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults) -> Set<UUID> {
        guard let raw = defaults.array(forKey: graceAppliedKey) as? [String] else {
            return []
        }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    static func saveGraceAppliedIDs(_ ids: Set<UUID>, defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults) {
        defaults.set(ids.map(\.uuidString), forKey: graceAppliedKey)
    }

    @MainActor
    static func routeLimitReachedToDisarm(
        intentID: UUID,
        alarms: [AlarmDefinition],
        persistence: AlarmPersistence,
        alarmManager: any AlarmManagerScheduling,
        defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults
    ) async {
        var pendingDisarm = persistence.loadPendingDisarmAlarmIDs()
        pendingDisarm.insert(intentID)
        persistence.savePendingDisarmAlarmIDs(pendingDisarm)
        try? alarmManager.stop(id: intentID)

        let alertReferences = AlertReferenceStore(defaults: defaults)
        guard let resolved = Self.resolveParentAlarm(
            for: intentID,
            in: alarms,
            persistence: persistence,
            alertReferenceStore: alertReferences
        ) else {
            return
        }

        let effectiveTaskCount = persistence.effectiveTasks(from: resolved.settings).count
        let needsProtection = effectiveTaskCount > 0 || resolved.settings.wakeUpCheckEnabled
        IntentDiagnostics.log("SnoozeIntent limit parent=\(resolved.alarm.id.uuidString) tasks=\(effectiveTaskCount) wakeCheck=\(resolved.settings.wakeUpCheckEnabled) protect=\(needsProtection)")
        if needsProtection {
            await Self.scheduleDisarmBackstop(
                for: resolved.alarm,
                settings: resolved.settings,
                replacing: BackstopSlotStore.backstopID(forParent: resolved.alarm.id, defaults: defaults),
                intentID: intentID,
                persistence: persistence,
                alarmManager: alarmManager,
                defaults: defaults
            )
        } else if let backstopID = BackstopSlotStore.clear(forParent: resolved.alarm.id, defaults: defaults) {
            try? alarmManager.stop(id: backstopID)
            try? alarmManager.cancel(id: backstopID)
            IntentDiagnostics.log("SnoozeIntent limit backstop cleared parent=\(resolved.alarm.id.uuidString) id=\(backstopID.uuidString) reason=no-protection")
        }
    }

    @MainActor
    static func deleteNap(
        napID: UUID,
        persistence: AlarmPersistence,
        alarmManager: any AlarmManagerScheduling,
        defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults,
        cancelNotification: @MainActor (String) -> Void
    ) async {
        var alarms = persistence.loadUserAlarms()
        alarms.removeAll { $0.id == napID }
        persistence.saveUserAlarms(alarms)
        LastRingtoneStore.clear(forAlarm: napID, defaults: defaults)

        var pendingDisarm = persistence.loadPendingDisarmAlarmIDs()
        if pendingDisarm.remove(napID) != nil {
            persistence.savePendingDisarmAlarmIDs(pendingDisarm)
            IntentDiagnostics.log("NapDelete pending removal id=\(napID.uuidString)")
        }

        var wakeCheckSessions = persistence.loadWakeCheckSessions()
        if let session = wakeCheckSessions.removeValue(forKey: napID) {
            persistence.saveWakeCheckSessions(wakeCheckSessions)
            cancelNotification(session.notificationID)
            IntentDiagnostics.log(
                "NapDelete wake-check session removed id=\(napID.uuidString) notification=\(session.notificationID)"
            )
        }

        var pendingWakeCheckConfirmUIIDs = persistence.loadPendingWakeUpCheckShowConfirmUIIDs()
        if pendingWakeCheckConfirmUIIDs.remove(napID) != nil {
            persistence.savePendingWakeUpCheckShowConfirmUIIDs(pendingWakeCheckConfirmUIIDs)
            IntentDiagnostics.log("NapDelete wake-check confirm removal id=\(napID.uuidString)")
        }

        if let backstopID = BackstopSlotStore.clear(forParent: napID, defaults: defaults) {
            IntentDiagnostics.log("NapDelete backstop cleared parent=\(napID.uuidString) id=\(backstopID.uuidString)")
            try? alarmManager.stop(id: backstopID)
            try? alarmManager.cancel(id: backstopID)
        }

        try? alarmManager.stop(id: napID)
        try? alarmManager.cancel(id: napID)
    }
}
