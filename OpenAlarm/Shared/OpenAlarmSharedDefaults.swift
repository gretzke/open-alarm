import Foundation
import os

enum OpenAlarmSharedDefaults {
    static let appGroupSuiteName = "group.com.gretzke.openalarm"
    private static let logger = Logger(subsystem: "com.openalarm", category: "persistence")

    /// Keys shared across processes (app + intents/extensions). Kept here so
    /// no target re-types them as string literals (drift risk).
    enum Key {
        static let backstopSlots = "OPENALARM_BACKSTOP_SLOTS_V1"
        static let diagnosticsLog = "OPENALARM_DIAGNOSTICS_LOG"
        static let wakeCheckGraceAppliedIDs = "OPENALARM_WAKE_CHECK_GRACE_APPLIED_IDS"
        static let legacyBackstopAlarmID = "OPENALARM_FORCE_CLOSE_ALARM_ID"
        static let legacyBackstopParentAlarmID = "OPENALARM_FORCE_CLOSE_PARENT_ALARM_ID"
        static let alertReferencePrefix = "OPENALARM_ALERT_REFERENCE_V1_"
    }

    // UserDefaults is documented thread-safe; Swift 6 can't see that.
    nonisolated(unsafe) static let userDefaults: UserDefaults = {
        if let defaults = UserDefaults(suiteName: appGroupSuiteName) {
            return defaults
        }
        logger.fault("App-group UserDefaults suite unavailable; falling back to standard defaults")
        return .standard
    }()
}
