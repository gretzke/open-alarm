import Foundation
import Testing

@testable import OpenAlarm

@MainActor
struct AlarmSettingsBackupCoordinatorTests {
    @Test
    func freshInstallRestoresCloudSettings() throws {
        let context = try TestContext()
        defer { context.cleanUp() }

        let remote = makeBackup(snoozeMinutes: 12, napMinutes: 65, pinVolume: false)
        context.cloudStore.saveBackup(remote)

        let restored = context.coordinator.bootstrap()

        #expect(restored)
        #expect(context.persistence.loadDefaultSharedSettings() == remote.defaultSharedSettings)
        #expect(context.persistence.loadDefaultNapDurationMinutes() == 65)
        #expect(context.persistence.loadPinAlarmVolumeEnabled() == false)
        #expect(context.persistence.loadUserAlarms().isEmpty)
        #expect(context.coordinator.isAwaitingInitialRestore == false)
    }

    @Test
    func establishedInstallWithExistingCompatibleCloudBackupDoesNotWrite() throws {
        let context = try TestContext()
        defer { context.cleanUp() }

        var localSettings = SharedAlarmSettings.featureDefaults
        localSettings.snoozeDurationMinutes = 8
        context.persistence.saveDefaultSharedSettings(localSettings)
        context.cloudStore.saveBackup(makeBackup(snoozeMinutes: 19))
        let writesBeforeBootstrap = context.keyValueStore.writeCount

        let restored = context.coordinator.bootstrap()

        #expect(restored == false)
        #expect(context.persistence.loadDefaultSharedSettings() == localSettings)
        #expect(context.keyValueStore.writeCount == writesBeforeBootstrap)
        #expect(context.persistence.hasSeededICloudAlarmSettingsBackup())
    }

    @Test
    func establishedInstallWithColdCacheDefersSeeding() throws {
        let context = try TestContext()
        defer { context.cleanUp() }

        context.persistence.saveDefaultSharedSettings(.featureDefaults)

        #expect(context.coordinator.bootstrap() == false)
        #expect(context.keyValueStore.writeCount == 0)
        #expect(context.coordinator.isAwaitingInitialSeed)
        #expect(context.persistence.hasSeededICloudAlarmSettingsBackup() == false)
    }

    @Test
    func establishedInstallSeedsAfterInitialSyncConfirmsCloudIsEmpty() throws {
        let context = try TestContext()
        defer { context.cleanUp() }

        context.persistence.saveDefaultSharedSettings(.featureDefaults)

        #expect(context.coordinator.bootstrap() == false)
        #expect(context.coordinator.handleCloudChange(initialSyncCompleted: true) == false)
        #expect(context.keyValueStore.writeCount == 1)
        #expect(context.coordinator.isAwaitingInitialSeed == false)
        #expect(context.persistence.hasSeededICloudAlarmSettingsBackup())
    }

    @Test
    func establishedInstallWithCloudBackupAfterInitialSyncDoesNotImportOrWrite() throws {
        let context = try TestContext()
        defer { context.cleanUp() }

        var localSettings = SharedAlarmSettings.featureDefaults
        localSettings.snoozeDurationMinutes = 8
        context.persistence.saveDefaultSharedSettings(localSettings)

        #expect(context.coordinator.bootstrap() == false)
        context.cloudStore.saveBackup(makeBackup(snoozeMinutes: 19))
        let writesBeforeInitialSync = context.keyValueStore.writeCount

        #expect(context.coordinator.handleCloudChange(initialSyncCompleted: true) == false)
        #expect(context.persistence.loadDefaultSharedSettings() == localSettings)
        #expect(context.keyValueStore.writeCount == writesBeforeInitialSync)
        #expect(context.coordinator.isAwaitingInitialSeed == false)
        #expect(context.persistence.hasSeededICloudAlarmSettingsBackup())
    }

    @Test
    func userChangeDuringEstablishedInstallSeedWindowWritesImmediately() throws {
        let context = try TestContext()
        defer { context.cleanUp() }

        context.persistence.saveDefaultSharedSettings(.featureDefaults)

        #expect(context.coordinator.bootstrap() == false)

        var localSettings = SharedAlarmSettings.featureDefaults
        localSettings.snoozeDurationMinutes = 9
        context.persistence.saveDefaultSharedSettings(localSettings)
        context.coordinator.localAlarmConfigurationDidChange()

        let backup = try #require(context.cloudStore.loadBackup())
        #expect(backup.defaultSharedSettings == localSettings)
        #expect(context.coordinator.isAwaitingInitialSeed == false)
        #expect(context.persistence.hasSeededICloudAlarmSettingsBackup())
    }

    @Test
    func automaticSaveDoesNotPreventLateCloudRestore() throws {
        let context = try TestContext()
        defer { context.cleanUp() }

        #expect(context.coordinator.bootstrap() == false)
        #expect(context.coordinator.isAwaitingInitialRestore)
        #expect(context.keyValueStore.writeCount == 0)

        let remote = makeBackup(snoozeMinutes: 14)
        context.cloudStore.saveBackup(remote)

        #expect(context.coordinator.handleCloudChange(initialSyncCompleted: true))
        #expect(context.persistence.loadDefaultSharedSettings() == remote.defaultSharedSettings)
    }

    @Test
    func localChangePreventsLateCloudRestore() throws {
        let context = try TestContext()
        defer { context.cleanUp() }

        #expect(context.coordinator.bootstrap() == false)

        var localSettings = SharedAlarmSettings.featureDefaults
        localSettings.snoozeDurationMinutes = 9
        context.persistence.saveDefaultSharedSettings(localSettings)
        context.coordinator.localAlarmConfigurationDidChange()

        context.cloudStore.saveBackup(makeBackup(snoozeMinutes: 17))

        #expect(context.coordinator.handleCloudChange(initialSyncCompleted: true) == false)
        #expect(context.persistence.loadDefaultSharedSettings() == localSettings)
    }

    @Test
    func initialSyncWithoutBackupSeedsFeatureDefaults() throws {
        let context = try TestContext()
        defer { context.cleanUp() }

        #expect(context.coordinator.bootstrap() == false)
        #expect(context.coordinator.handleCloudChange(initialSyncCompleted: true) == false)

        let backup = try #require(context.cloudStore.loadBackup())
        #expect(backup.defaultSharedSettings == .featureDefaults)
        #expect(backup.defaultNapDurationMinutes == 35)
        #expect(backup.pinAlarmVolumeEnabled)
        #expect(context.coordinator.isAwaitingInitialRestore == false)
        #expect(context.persistence.hasEstablishedLocalAlarmData())
    }

    @Test
    func incompatibleCloudBackupIsNeverOverwritten() throws {
        let keyValueStore = FakeUbiquitousKeyValueStore()
        let cloudStore = ICloudAlarmSettingsStore(keyValueStore: keyValueStore)
        let suiteName = "openalarm-cloud-incompatible-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = AlarmPersistence(defaults: defaults)
        let coordinator = AlarmSettingsBackupCoordinator(
            persistence: persistence,
            cloudStore: cloudStore
        )

        #expect(coordinator.bootstrap() == false)
        #expect(coordinator.isAwaitingInitialRestore)

        cloudStore.saveBackup(makeBackup(schemaVersion: 99, snoozeMinutes: 13))
        switch cloudStore.probeBackup() {
        case .incompatible:
            break
        case .empty, .compatible:
            Issue.record("Expected an incompatible cloud backup.")
        }
        let writesBeforeInitialSync = keyValueStore.writeCount

        #expect(coordinator.handleCloudChange(initialSyncCompleted: true) == false)
        #expect(keyValueStore.writeCount == writesBeforeInitialSync)
        #expect(persistence.hasSeededICloudAlarmSettingsBackup())
        #expect(coordinator.isAwaitingInitialRestore == false)
    }

    private func makeBackup(
        schemaVersion: Int = AlarmSettingsBackup.currentSchemaVersion,
        snoozeMinutes: Int,
        napMinutes: Int = 35,
        pinVolume: Bool = true
    ) -> AlarmSettingsBackup {
        var settings = SharedAlarmSettings.featureDefaults
        settings.snoozeEnabled = true
        settings.snoozeDurationMinutes = snoozeMinutes
        return AlarmSettingsBackup(
            schemaVersion: schemaVersion,
            defaultSharedSettings: settings,
            napDefaultSharedSettings: nil,
            defaultNapDurationMinutes: napMinutes,
            pinAlarmVolumeEnabled: pinVolume,
            updatedAt: Date(timeIntervalSinceReferenceDate: 123)
        )
    }
}

@MainActor
private struct TestContext {
    let suiteName: String
    let defaults: UserDefaults
    let persistence: AlarmPersistence
    let keyValueStore: FakeUbiquitousKeyValueStore
    let cloudStore: ICloudAlarmSettingsStore
    let coordinator: AlarmSettingsBackupCoordinator

    init() throws {
        suiteName = "openalarm-cloud-coordinator-tests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        persistence = AlarmPersistence(defaults: defaults)
        keyValueStore = FakeUbiquitousKeyValueStore()
        cloudStore = ICloudAlarmSettingsStore(keyValueStore: keyValueStore)
        coordinator = AlarmSettingsBackupCoordinator(persistence: persistence, cloudStore: cloudStore)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class FakeUbiquitousKeyValueStore: UbiquitousKeyValueStoring {
    private var values: [String: Any] = [:]
    private(set) var writeCount = 0

    func data(forKey defaultName: String) -> Data? {
        values[defaultName] as? Data
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
        writeCount += 1
    }

    func synchronize() -> Bool {
        true
    }
}
