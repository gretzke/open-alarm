import Foundation

enum IntentDiagnostics {
    private static let maxEntries = 100
    private static let key = OpenAlarmSharedDefaults.Key.diagnosticsLog
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: String, defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults) {
        lock.lock()
        defer { lock.unlock() }
        let entry = "\(formatter.string(from: Date())) \(message)"
        var current = defaults.array(forKey: key) as? [String] ?? []
        current.append(entry)
        if current.count > maxEntries {
            current = Array(current.suffix(maxEntries))
        }
        defaults.set(current, forKey: key)
    }

    static func entries(defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return defaults.array(forKey: key) as? [String] ?? []
    }

    static func clear(defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults) {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }
}
