import AlarmKit
import AppIntents
import Foundation
import UserNotifications

struct StopIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop"
    static var description = IntentDescription("Stop an alarm")
    static var openAppWhenRun: Bool = true

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

        // Mark as pending disarm FIRST (tiny write, near-instant).
        // The app handles all lifecycle logic when it opens.
        let persistence = AlarmPersistence(defaults: .standard)
        var pendingDisarm = persistence.loadPendingDisarmAlarmIDs()
        pendingDisarm.insert(id)
        persistence.savePendingDisarmAlarmIDs(pendingDisarm)

        // Silence the alarm
        try? AlarmManager.shared.stop(id: id)

        // Also stop any active force-close alarm (has a different UUID)
        if let forceCloseIDStr = UserDefaults.standard.string(forKey: "OPENALARM_FORCE_CLOSE_ALARM_ID"),
           let forceCloseID = UUID(uuidString: forceCloseIDStr) {
            try? AlarmManager.shared.stop(id: forceCloseID)
            try? AlarmManager.shared.cancel(id: forceCloseID)
        }

        // Notify AlarmStore if it's alive (in-process notification)
        NotificationCenter.default.post(name: .disarmChallengeRequested, object: nil)

        return .result()
    }

    // MARK: - Grace period helpers (shared key with AlarmStore)

    private static let graceAppliedKey = "OPENALARM_WAKE_CHECK_GRACE_APPLIED_IDS"

    static func loadGraceAppliedIDs() -> Set<UUID> {
        guard let raw = UserDefaults.standard.array(forKey: graceAppliedKey) as? [String] else {
            return []
        }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    static func saveGraceAppliedIDs(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: graceAppliedKey)
    }
}
