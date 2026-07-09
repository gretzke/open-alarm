import Foundation
import os

enum OpenAlarmSharedDefaults {
    static let appGroupSuiteName = "group.com.gretzke.openalarm"
    private static let logger = Logger(subsystem: "com.openalarm", category: "persistence")

    /// Keys shared across processes (app + intents/extensions). Kept here so
    /// no target re-types them as string literals (drift risk).
    enum Key {
        static let forceCloseAlarmID = "OPENALARM_FORCE_CLOSE_ALARM_ID"
        static let wakeCheckGraceAppliedIDs = "OPENALARM_WAKE_CHECK_GRACE_APPLIED_IDS"
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
