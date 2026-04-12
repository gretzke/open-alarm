import Foundation

enum OpenAlarmSharedDefaults {
    static let appGroupSuiteName = "group.com.gretzke.openalarm"

    static let userDefaults: UserDefaults = {
        UserDefaults(suiteName: appGroupSuiteName) ?? .standard
    }()
}
