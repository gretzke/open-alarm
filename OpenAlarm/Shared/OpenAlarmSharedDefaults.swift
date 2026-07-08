import Foundation

enum OpenAlarmSharedDefaults {
    static let appGroupSuiteName = "group.com.gretzke.openalarm"

    // UserDefaults is documented thread-safe; Swift 6 can't see that.
    nonisolated(unsafe) static let userDefaults: UserDefaults = {
        UserDefaults(suiteName: appGroupSuiteName) ?? .standard
    }()
}
