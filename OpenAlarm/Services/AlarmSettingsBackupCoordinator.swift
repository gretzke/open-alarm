import Foundation

@MainActor
final class AlarmSettingsBackupCoordinator {
    private let persistence: AlarmPersistence
    private let cloudStore: ICloudAlarmSettingsStore

    private(set) var isAwaitingInitialRestore = false
    private(set) var isAwaitingInitialSeed = false
    private var cloudHasIncompatibleBackup = false

    var notificationObject: AnyObject {
        cloudStore.notificationObject
    }

    init(persistence: AlarmPersistence, cloudStore: ICloudAlarmSettingsStore) {
        self.persistence = persistence
        self.cloudStore = cloudStore
    }

    var needsCloudObservation: Bool {
        isAwaitingInitialRestore
            || isAwaitingInitialSeed
            || !persistence.hasEstablishedLocalAlarmData()
            || !persistence.hasSeededICloudAlarmSettingsBackup()
    }

    @discardableResult
    func bootstrap() -> Bool {
        cloudStore.requestInitialSync()
        let probe = cloudStore.probeBackup()
        if case .incompatible = probe {
            cloudHasIncompatibleBackup = true
        }

        if persistence.hasEstablishedLocalAlarmData() {
            if !persistence.hasSeededICloudAlarmSettingsBackup() {
                switch probe {
                case .empty:
                    isAwaitingInitialSeed = true
                case .compatible, .incompatible:
                    persistence.markICloudAlarmSettingsBackupSeeded()
                }
            }
            return false
        }

        switch probe {
        case .compatible(let backup):
            restore(backup)
            return true
        case .incompatible:
            saveCurrentSettings()
            return false
        case .empty:
            isAwaitingInitialRestore = true
            return false
        }
    }

    @discardableResult
    func handleCloudChange(initialSyncCompleted: Bool) -> Bool {
        guard isAwaitingInitialRestore || isAwaitingInitialSeed else {
            return false
        }

        let probe = cloudStore.probeBackup()
        if isAwaitingInitialSeed {
            switch probe {
            case .compatible:
                persistence.markICloudAlarmSettingsBackupSeeded()
                isAwaitingInitialSeed = false
            case .incompatible:
                cloudHasIncompatibleBackup = true
                persistence.markICloudAlarmSettingsBackupSeeded()
                isAwaitingInitialSeed = false
            case .empty:
                if initialSyncCompleted {
                    saveCurrentSettings()
                }
            }

            return false
        }

        switch probe {
        case .compatible(let backup):
            restore(backup)
            return true
        case .incompatible:
            cloudHasIncompatibleBackup = true
            saveCurrentSettings()
        case .empty:
            if initialSyncCompleted {
                saveCurrentSettings()
            }
        }

        return false
    }

    func localAlarmConfigurationDidChange() {
        saveCurrentSettings()
    }

    func isInitialSync(_ notification: Notification) -> Bool {
        cloudStore.isInitialSync(notification)
    }

    private func restore(_ backup: AlarmSettingsBackup) {
        persistence.restoreAlarmSettings(from: backup)
        persistence.markICloudAlarmSettingsBackupSeeded()
        isAwaitingInitialRestore = false
        isAwaitingInitialSeed = false
    }

    private func saveCurrentSettings() {
        guard !cloudHasIncompatibleBackup else {
            persistence.markICloudAlarmSettingsBackupSeeded()
            isAwaitingInitialRestore = false
            isAwaitingInitialSeed = false
            return
        }

        cloudStore.saveBackup(persistence.makeAlarmSettingsBackup())
        persistence.markICloudAlarmSettingsBackupSeeded()
        isAwaitingInitialRestore = false
        isAwaitingInitialSeed = false
    }
}
