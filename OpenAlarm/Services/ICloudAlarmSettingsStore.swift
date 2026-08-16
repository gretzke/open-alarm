import Foundation
import os

enum CloudBackupProbe {
    case empty
    case compatible(AlarmSettingsBackup)
    case incompatible
}

@MainActor
final class ICloudAlarmSettingsStore {
    private static let logger = Logger(subsystem: "com.openalarm", category: "ICloudAlarmSettingsStore")
    private static let backupKey = "OPENALARM_ICLOUD_ALARM_SETTINGS_V1"

    let notificationObject: AnyObject

    private let keyValueStore: any UbiquitousKeyValueStoring

    init(keyValueStore: any UbiquitousKeyValueStoring = NSUbiquitousKeyValueStore.default) {
        self.keyValueStore = keyValueStore
        self.notificationObject = keyValueStore
    }

    func requestInitialSync() {
        keyValueStore.synchronize()
    }

    func loadBackup() -> AlarmSettingsBackup? {
        guard case .compatible(let backup) = probeBackup() else {
            return nil
        }

        return backup
    }

    func probeBackup() -> CloudBackupProbe {
        guard let data = keyValueStore.data(forKey: Self.backupKey) else {
            return .empty
        }

        do {
            let backup = try JSONDecoder().decode(AlarmSettingsBackup.self, from: data)
            guard backup.schemaVersion == AlarmSettingsBackup.currentSchemaVersion else {
                Self.logger.error("Unsupported iCloud alarm settings schema: \(backup.schemaVersion)")
                return .incompatible
            }
            return .compatible(backup)
        } catch {
            Self.logger.error("Failed to decode iCloud alarm settings: \(error.localizedDescription)")
            return .incompatible
        }
    }

    func saveBackup(_ backup: AlarmSettingsBackup) {
        do {
            keyValueStore.set(try JSONEncoder().encode(backup), forKey: Self.backupKey)
        } catch {
            Self.logger.error("Failed to encode iCloud alarm settings: \(error.localizedDescription)")
        }
    }

    func isInitialSync(_ notification: Notification) -> Bool {
        guard
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? NSNumber
        else {
            return false
        }

        return reason.intValue == NSUbiquitousKeyValueStoreInitialSyncChange
    }
}
