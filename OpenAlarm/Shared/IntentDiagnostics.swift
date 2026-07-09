import Foundation

enum IntentDiagnostics {
    private static let maxEntries = 100
    private static let key = OpenAlarmSharedDefaults.Key.diagnosticsLog

    static func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        let entry = "\(formatter.string(from: Date())) \(message)"
        let defaults = OpenAlarmSharedDefaults.userDefaults
        var current = defaults.array(forKey: key) as? [String] ?? []
        current.append(entry)
        if current.count > maxEntries {
            current = Array(current.suffix(maxEntries))
        }
        defaults.set(current, forKey: key)
    }

    static func entries() -> [String] {
        OpenAlarmSharedDefaults.userDefaults.array(forKey: key) as? [String] ?? []
    }

    static func clear() {
        OpenAlarmSharedDefaults.userDefaults.removeObject(forKey: key)
    }
}
