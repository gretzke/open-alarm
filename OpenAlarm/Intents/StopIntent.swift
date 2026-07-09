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

        let persistedBackstopID = Self.loadPersistedForceCloseAlarmID()
        if id == persistedBackstopID {
            IntentDiagnostics.log("StopIntent entry id=\(id.uuidString) case=backstop-restop")
            await handleStoppedBackstop(id)
            await requestForegroundEscalation(caseName: "backstop-restop")
            return .result()
        }
        IntentDiagnostics.log("StopIntent entry id=\(id.uuidString) case=normal")

        let persistence = AlarmPersistence(defaults: OpenAlarmSharedDefaults.userDefaults)

        // Mark as pending disarm FIRST (tiny write, near-instant).
        // The app handles all lifecycle logic when it opens.
        var pendingDisarm = persistence.loadPendingDisarmAlarmIDs()
        pendingDisarm.insert(id)
        persistence.savePendingDisarmAlarmIDs(pendingDisarm)

        // Silence the alarm
        try? AlarmManager.shared.stop(id: id)

        // Also stop any active force-close alarm (has a different UUID)
        if let forceCloseID = persistedBackstopID {
            try? AlarmManager.shared.stop(id: forceCloseID)
            try? AlarmManager.shared.cancel(id: forceCloseID)
            Self.clearPersistedForceCloseSlot()
        }

        // Notify AlarmStore if it's alive (in-process notification)
        NotificationCenter.default.post(name: .disarmChallengeRequested, object: nil)

        if let resolved = Self.resolveParentAlarm(for: id, persistence: persistence) {
            IntentDiagnostics.log("StopIntent normal parent=\(resolved.alarm.id.uuidString) tasks=\(resolved.settings.tasks.count)")
            if !resolved.settings.tasks.isEmpty {
                await Self.scheduleDisarmBackstop(
                    for: resolved.alarm,
                    settings: resolved.settings,
                    cancelAfterRegistering: nil
                )
            } else {
                Self.clearPersistedForceCloseParentAlarmID()
            }
        } else {
            IntentDiagnostics.log("StopIntent normal parent=unresolved tasks=0")
            Self.clearPersistedForceCloseParentAlarmID()
        }

        await requestForegroundEscalation(caseName: "normal")
        return .result()
    }

    private func handleStoppedBackstop(_ id: UUID) async {
        try? AlarmManager.shared.stop(id: id)

        let persistence = AlarmPersistence(defaults: OpenAlarmSharedDefaults.userDefaults)
        guard let resolved = Self.resolvePersistedForceCloseParent(persistence: persistence) else {
            IntentDiagnostics.log("StopIntent backstop parent=unresolved tasks=0")
            try? AlarmManager.shared.cancel(id: id)
            Self.clearPersistedForceCloseSlot()
            return
        }
        IntentDiagnostics.log("StopIntent backstop parent=\(resolved.alarm.id.uuidString) tasks=\(resolved.settings.tasks.count)")

        guard !resolved.settings.tasks.isEmpty else {
            try? AlarmManager.shared.cancel(id: id)
            Self.clearPersistedForceCloseSlot()
            return
        }

        await Self.scheduleDisarmBackstop(
            for: resolved.alarm,
            settings: resolved.settings,
            cancelAfterRegistering: id
        )
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

    private static let forceCloseAlarmIDKey = OpenAlarmSharedDefaults.Key.forceCloseAlarmID
    private static let forceCloseParentAlarmIDKey = OpenAlarmSharedDefaults.Key.forceCloseParentAlarmID

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

    private static func resolvePersistedForceCloseParent(
        persistence: AlarmPersistence
    ) -> ResolvedAlarm? {
        guard let parentIDString = OpenAlarmSharedDefaults.userDefaults.string(forKey: forceCloseParentAlarmIDKey),
              let parentID = UUID(uuidString: parentIDString) else {
            return nil
        }
        guard let alarm = persistence.loadUserAlarms().first(where: { $0.id == parentID }) else {
            return nil
        }
        return resolvedAlarm(for: alarm, persistence: persistence)
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
        cancelAfterRegistering previousBackstopID: UUID?
    ) async {
        let newID = UUID()
        let fireDate = Date.now.addingTimeInterval(SchedulingConstants.disarmBackstopSeconds)
        let config = AlarmConfigurationBuilder.makeForceCloseAlarmConfiguration(
            for: alarm,
            fireAt: fireDate,
            resolvedSettings: settings,
            alarmKitID: newID
        )

        do {
            _ = try await AlarmManager.shared.schedule(id: newID, configuration: config)
        } catch {
            IntentDiagnostics.log("StopIntent backstop schedule failed id=\(newID.uuidString) parent=\(alarm.id.uuidString) error=\(error.localizedDescription)")
            return
        }

        IntentDiagnostics.log("StopIntent backstop schedule success id=\(newID.uuidString) parent=\(alarm.id.uuidString)")
        persistForceCloseSlot(backstopID: newID, parentAlarmID: alarm.id)

        if let previousBackstopID {
            try? AlarmManager.shared.cancel(id: previousBackstopID)
        }
    }

    private static func loadPersistedForceCloseAlarmID() -> UUID? {
        guard let str = OpenAlarmSharedDefaults.userDefaults.string(forKey: forceCloseAlarmIDKey) else {
            return nil
        }
        return UUID(uuidString: str)
    }

    private static func persistForceCloseSlot(backstopID: UUID, parentAlarmID: UUID) {
        OpenAlarmSharedDefaults.userDefaults.set(backstopID.uuidString, forKey: forceCloseAlarmIDKey)
        OpenAlarmSharedDefaults.userDefaults.set(parentAlarmID.uuidString, forKey: forceCloseParentAlarmIDKey)
    }

    private static func clearPersistedForceCloseSlot() {
        OpenAlarmSharedDefaults.userDefaults.removeObject(forKey: forceCloseAlarmIDKey)
        clearPersistedForceCloseParentAlarmID()
    }

    private static func clearPersistedForceCloseParentAlarmID() {
        OpenAlarmSharedDefaults.userDefaults.removeObject(forKey: forceCloseParentAlarmIDKey)
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
