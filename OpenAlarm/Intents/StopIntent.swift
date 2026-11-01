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

        if let resolved = AlarmIntentLifecycle.resolveParentAlarm(
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
                await AlarmIntentLifecycle.scheduleDisarmBackstop(
                    for: resolved.alarm,
                    settings: resolved.settings,
                    replacing: previous,
                    intentID: id,
                    persistence: persistence,
                    alarmManager: AlarmKitScheduler()
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

}
