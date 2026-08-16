import Foundation

struct AlarmSettingsBackup: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let defaultSharedSettings: SharedAlarmSettings
    let napDefaultSharedSettings: SharedAlarmSettings?
    let defaultNapDurationMinutes: Int
    let pinAlarmVolumeEnabled: Bool
    let updatedAt: Date

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        defaultSharedSettings: SharedAlarmSettings,
        napDefaultSharedSettings: SharedAlarmSettings?,
        defaultNapDurationMinutes: Int,
        pinAlarmVolumeEnabled: Bool,
        updatedAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.defaultSharedSettings = defaultSharedSettings
        self.napDefaultSharedSettings = napDefaultSharedSettings
        self.defaultNapDurationMinutes = max(0, defaultNapDurationMinutes)
        self.pinAlarmVolumeEnabled = pinAlarmVolumeEnabled
        self.updatedAt = updatedAt
    }
}
