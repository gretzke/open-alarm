import Foundation
import Testing

@testable import OpenAlarmSchedulingCore

struct AlarmSettingsBackupTests {
    @Test
    func backupRoundTripsAlarmPreferencesWithoutChangingAlarmList() throws {
        let suiteName = "openalarm-settings-backup-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = AlarmPersistence(defaults: defaults)
        let alarm = AlarmDefinition(name: "Local alarm", trigger: .time(hour: 7, minute: 15))
        persistence.saveUserAlarms([alarm])

        var globalSettings = SharedAlarmSettings.featureDefaults
        globalSettings.snoozeEnabled = true
        globalSettings.ringtoneID = "nature.rain"
        var napSettings = SharedAlarmSettings.featureDefaults
        napSettings.tasks = [.math(difficulty: .hard, count: 4)]

        let backup = AlarmSettingsBackup(
            defaultSharedSettings: globalSettings,
            napDefaultSharedSettings: napSettings,
            defaultNapDurationMinutes: 55,
            pinAlarmVolumeEnabled: false,
            updatedAt: Date(timeIntervalSinceReferenceDate: 123)
        )

        persistence.restoreAlarmSettings(from: backup)

        #expect(persistence.loadDefaultSharedSettings() == globalSettings)
        #expect(persistence.loadNapDefaultSharedSettings() == napSettings)
        #expect(persistence.loadDefaultNapDurationMinutes() == 55)
        #expect(persistence.loadPinAlarmVolumeEnabled() == false)
        #expect(persistence.loadUserAlarms() == [alarm])
    }

    @Test
    func exportedBackupContainsOnlyCurrentAlarmPreferences() throws {
        let suiteName = "openalarm-settings-export-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = AlarmPersistence(defaults: defaults)
        var settings = SharedAlarmSettings.featureDefaults
        settings.volume = AlarmVolumeSettings(targetPercent: 73)
        persistence.saveDefaultSharedSettings(settings)
        persistence.saveDefaultNapDurationMinutes(42)
        persistence.savePinAlarmVolumeEnabled(false)

        let updatedAt = Date(timeIntervalSinceReferenceDate: 456)
        let backup = persistence.makeAlarmSettingsBackup(updatedAt: updatedAt)

        #expect(backup.schemaVersion == AlarmSettingsBackup.currentSchemaVersion)
        #expect(backup.defaultSharedSettings == settings)
        #expect(backup.napDefaultSharedSettings == nil)
        #expect(backup.defaultNapDurationMinutes == 42)
        #expect(backup.pinAlarmVolumeEnabled == false)
        #expect(backup.updatedAt == updatedAt)
    }

    @Test
    func alarmDataCountsAsAnEstablishedLocalConfiguration() throws {
        let suiteName = "openalarm-established-alarm-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = AlarmPersistence(defaults: defaults)
        #expect(persistence.hasEstablishedLocalAlarmData() == false)

        persistence.saveUserAlarms([])

        #expect(persistence.hasEstablishedLocalAlarmData())
    }
}
