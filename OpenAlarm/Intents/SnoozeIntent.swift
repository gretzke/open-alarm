import AlarmKit
import AppIntents
import Foundation

struct SnoozeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "intent_snooze_title"
    static var description = IntentDescription("intent_snooze_description")
    static var openAppWhenRun: Bool = false

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
            return .result()
        }

        let persistence = AlarmPersistence(defaults: OpenAlarmSharedDefaults.userDefaults)
        let defaultSharedSettings = persistence.loadDefaultSharedSettings()
        var alarms = persistence.loadUserAlarms()

        // Look up by direct ID first, then by bridge ID
        var index = alarms.firstIndex(where: { $0.id == id })
        if index == nil {
            index = alarms.firstIndex(where: { $0.activeOverride?.bridgeAlarmIDs.contains(id) == true })
        }
        guard let index else {
            try? AlarmManager.shared.stop(id: id)
            return .result()
        }

        var alarm = alarms[index]
        let effectiveDefaults: SharedAlarmSettings = alarm.isNap
            ? (persistence.loadNapDefaultSharedSettings() ?? defaultSharedSettings)
            : defaultSharedSettings
        let settings = alarm.resolvedSharedSettings(defaults: effectiveDefaults)

        guard settings.canSnoozeAgain(currentCount: alarm.snoozeCount) else {
            // A snooze press that cannot snooze (stale configuration still
            // showing the button) must behave like a stop, not silently
            // consume the ring: queue the disarm first, crash-safe, so the
            // dismiss flow runs when the app opens.
            await Self.routeLimitReachedToDisarm(
                intentID: id,
                alarms: alarms,
                persistence: persistence,
                alarmManager: AlarmManager.shared
            )
            NotificationCenter.default.post(name: .disarmChallengeRequested, object: nil)
            await requestForegroundEscalation()
            IntentDiagnostics.log("SnoozeIntent limit reached, routed to disarm id=\(id.uuidString)")
            return .result()
        }

        alarm.snoozeCount += 1
        alarm.updatedAt = .now

        let snoozeSeconds = settings.snoozeDurationMinutes == 0
            ? SchedulingConstants.debugSentinelSeconds
            : TimeInterval(settings.snoozeDurationMinutes * 60)
        let snoozeDate = Date.now.addingTimeInterval(snoozeSeconds)

        if alarm.isNap {
            alarm.fixedTriggerDate = snoozeDate
            alarm.pausedRemainingSeconds = nil
        }

        alarms[index] = alarm
        persistence.saveUserAlarms(alarms)

        let isBridgeAlarm = alarm.activeOverride?.bridgeAlarmIDs.contains(id) == true
        let config: AlarmManager.AlarmConfiguration<OpenAlarmMetadata>
        if isBridgeAlarm {
            config = AlarmConfigurationBuilder.makeBridgeConfiguration(
                for: alarm,
                bridgeID: id,
                schedule: .fixed(snoozeDate),
                defaultSharedSettings: effectiveDefaults
            )
        } else {
            config = AlarmConfigurationBuilder.makeConfiguration(
                for: alarm,
                schedule: .fixed(snoozeDate),
                defaultSharedSettings: effectiveDefaults
            )
        }

        // Stop first, cancel, then schedule fresh
        try? AlarmManager.shared.stop(id: id)
        try? AlarmManager.shared.cancel(id: id)
        AlertReferenceStore().record(
            AlertReference(
                expectedFireDate: snoozeDate,
                ringtoneID: RingtoneCatalog.resolve(settings.ringtoneID).id,
                parentAlarmID: alarm.id
            ),
            alarmKitID: id
        )
        _ = try? await AlarmManager.shared.schedule(id: id, configuration: config)

        if alarm.isNap {
            let updatedNap = alarm
            await MainActor.run {
                NapCountdownLiveActivityManager.shared.sync(with: updatedNap)
            }
        }

        return .result()
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
        guard let resolved = StopIntent.resolveParentAlarm(
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
            await StopIntent.scheduleDisarmBackstop(
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

    private func requestForegroundEscalation() async {
        do {
            try await continueInForeground(alwaysConfirm: false)
            IntentDiagnostics.log("SnoozeIntent foreground success case=limit")
        } catch {
            IntentDiagnostics.log("SnoozeIntent foreground failed case=limit error=\(error.localizedDescription)")
        }
    }
}
