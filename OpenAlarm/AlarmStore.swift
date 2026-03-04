import AlarmKit
import AppIntents
import Combine
import Foundation

@MainActor
final class AlarmStore: ObservableObject {
    @Published internal var alarms: [UserAlarm] = []
    @Published var defaultSharedSettings: SharedAlarmSettings
    @Published var defaultNapDurationMinutes: Int
    @Published var testingModeEnabled: Bool

    /// The single active nap alarm, derived from the unified alarms array.
    var activeNap: UserAlarm? {
        alarms.first { $0.isNap }
    }

    /// Alarms visible in the main list (excludes nap and tryOut).
    var regularAlarms: [UserAlarm] {
        alarms.filter { $0.alarmType == .regular }
    }

    @Published internal var permissionStatus: AlarmPermissionStatus
    @Published internal var notificationPermissionStatus: NotificationPermissionStatus = .notDetermined
    @Published internal var remoteStates: [UUID: Alarm.State] = [:]

    let alarmManager: AlarmManager
    private let permissionService: AlarmPermissionService
    private let notificationPermissionService: NotificationPermissionService
    let persistence: AlarmPersistence

    private var alarmUpdatesTask: Task<Void, Never>?
    var lastKnownAlarmState: [UUID: Alarm.State] = [:]
    private(set) var wakeUpCheckController: WakeUpCheckPipelineController!
    private(set) var scheduleCoordinator: AlarmScheduleCoordinator!

    /// When temporary schedule override is active, we keep this many explicit
    /// one-shot alarms queued as fallback bridges.
    let manualOverrideQueueDepth = AlarmSchedulePlanner.defaultManualQueueDepth

    init(
        alarmManager: AlarmManager = .shared,
        permissionService: AlarmPermissionService? = nil,
        notificationPermissionService: NotificationPermissionService? = nil,
        wakeUpCheckNotificationService: WakeUpCheckNotificationService? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.alarmManager = alarmManager
        self.permissionService = permissionService ?? AlarmPermissionService(manager: alarmManager)
        self.notificationPermissionService = notificationPermissionService ?? NotificationPermissionService()
        let wakeNotifService = wakeUpCheckNotificationService ?? WakeUpCheckNotificationService()
        self.persistence = AlarmPersistence(defaults: userDefaults)
        self.defaultSharedSettings = persistence.loadDefaultSharedSettings()
        self.defaultNapDurationMinutes = persistence.loadDefaultNapDurationMinutes()
        self.testingModeEnabled = persistence.loadTestingModeEnabled()
        self.permissionStatus = self.permissionService.currentStatus()

        self.wakeUpCheckController = WakeUpCheckPipelineController(
            persistence: persistence,
            notificationService: wakeNotifService,
            alarmManager: alarmManager
        )

        wireWakeUpCheckControllerCallbacks()

        self.scheduleCoordinator = AlarmScheduleCoordinator(
            alarmManager: alarmManager,
            persistence: persistence,
            wakeUpCheckController: wakeUpCheckController,
            manualOverrideQueueDepth: manualOverrideQueueDepth
        )

        wireScheduleCoordinatorCallbacks()
        wireWakeUpCheckCoordinatorDependencies()
        applyLegacyWakeCheckMigration()

        wakeNotifService.ensureCategoryRegistered()
        AlarmScheduleReconcileEntrypoint.register(handler: scheduleCoordinator)

        load()
        observeAlarmUpdates()
        refreshFromSystem()

        Task { @MainActor [weak self] in
            await self?.refreshNotificationPermissionStatus()
            await AlarmScheduleReconcileEntrypoint.reconcile(trigger: .appLaunch)
        }
    }

    deinit {
        alarmUpdatesTask?.cancel()
    }

    // MARK: - App lifecycle

    func handleAppOpened() {
        refreshFromSystem()

        Task { @MainActor [weak self] in
            await self?.refreshNotificationPermissionStatus()
            await AlarmScheduleReconcileEntrypoint.reconcile(trigger: .appLaunch)
        }
    }

    // MARK: - Permissions

    func requestPermissionIfNeeded() async -> AlarmPermissionStatus {
        switch permissionService.currentStatus() {
        case .notDetermined:
            permissionStatus = await permissionService.requestAuthorization()
        case .denied:
            permissionStatus = .denied
        case .authorized:
            permissionStatus = .authorized
        }
        return permissionStatus
    }

    @discardableResult
    func refreshNotificationPermissionStatus() async -> NotificationPermissionStatus {
        notificationPermissionStatus = await notificationPermissionService.currentStatus()
        return notificationPermissionStatus
    }

    func requestNotificationPermissionIfNeeded() async -> NotificationPermissionStatus {
        let status = await refreshNotificationPermissionStatus()

        switch status {
        case .notDetermined:
            notificationPermissionStatus = await notificationPermissionService.requestAuthorization()
        case .authorized, .denied:
            break
        }

        return notificationPermissionStatus
    }

    func shouldPresentWakeCheckPermissionDeniedPromptOnLaunch() async -> Bool {
        let status = await refreshNotificationPermissionStatus()
        guard status == .denied else {
            return false
        }

        return hasWakeUpCheckEnabledConfigurationWithNotificationRequirement
    }

    // MARK: - Default settings

    func updateDefaultSharedSettings(_ settings: SharedAlarmSettings) {
        guard defaultSharedSettings != settings else {
            return
        }

        defaultSharedSettings = settings
        persistence.saveDefaultSharedSettings(settings)

        var changed = false
        for index in alarms.indices where alarms[index].useDefaultSharedSettings {
            alarms[index].customSharedSettings = settings
            alarms[index].updatedAt = .now
            changed = true
        }

        if changed {
            alarms = sortAlarms(alarms)
            save()

            Task { @MainActor [weak self] in
                await self?.rescheduleAlarmsUsingDefaultSharedSettings()
            }
        }
    }

    func disableWakeUpCheckFeatureGlobally() {
        var defaults = defaultSharedSettings
        if defaults.wakeUpCheckEnabled {
            defaults.wakeUpCheckEnabled = false
            defaultSharedSettings = defaults
            persistence.saveDefaultSharedSettings(defaults)
        }

        var changed = false
        for index in alarms.indices {
            guard !alarms[index].useDefaultSharedSettings else {
                continue
            }

            if alarms[index].customSharedSettings.wakeUpCheckEnabled {
                alarms[index].customSharedSettings.wakeUpCheckEnabled = false
                alarms[index].updatedAt = .now
                changed = true
            }
        }

        if changed {
            alarms = sortAlarms(alarms)
            save()
        }

        wakeUpCheckController.clearAllWakeUpCheckSessions(restoreSchedules: true)
    }

    func updateTestingModeEnabled(_ enabled: Bool) {
        guard testingModeEnabled != enabled else {
            return
        }

        testingModeEnabled = enabled
        persistence.saveTestingModeEnabled(enabled)
    }

    func updateDefaultNapDurationMinutes(_ minutes: Int) {
        let next = max(1, minutes)
        guard defaultNapDurationMinutes != next else {
            return
        }

        defaultNapDurationMinutes = next
        persistence.saveDefaultNapDurationMinutes(next)
    }

    // MARK: - Persistence helpers

    func persistCommittedAlarm(_ alarm: UserAlarm) {
        if let existingIndex = alarms.firstIndex(where: { $0.id == alarm.id }) {
            alarms[existingIndex] = alarm
        } else {
            alarms.append(alarm)
        }

        alarms = sortAlarms(alarms)
        save()
    }

    func sortAlarms(_ alarms: [UserAlarm]) -> [UserAlarm] {
        alarms.sorted { lhs, rhs in
            if lhs.hour == rhs.hour {
                if lhs.minute == rhs.minute {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.minute < rhs.minute
            }
            return lhs.hour < rhs.hour
        }
    }

    func mergeSnoozeCountsFromPersistence(into alarms: inout [UserAlarm]) -> Bool {
        let persisted = Dictionary(uniqueKeysWithValues: persistence.loadUserAlarms().map { ($0.id, $0.snoozeCount) })

        var changed = false
        for index in alarms.indices {
            guard let persistedCount = persisted[alarms[index].id] else {
                continue
            }
            if alarms[index].snoozeCount != persistedCount {
                alarms[index].snoozeCount = persistedCount
                changed = true
            }
        }
        return changed
    }

    func load() {
        alarms = sortAlarms(persistence.loadUserAlarms())
    }

    func save() {
        persistence.saveUserAlarms(alarms)
    }

    // MARK: - Remote observation

    private func observeAlarmUpdates() {
        alarmUpdatesTask = Task { [weak self] in
            guard let self else {
                return
            }

            for await incoming in alarmManager.alarmUpdates {
                if Task.isCancelled {
                    return
                }

                applyRemoteAlarms(incoming)
                await AlarmScheduleReconcileEntrypoint.reconcileAllSchedules()
            }
        }
    }

    private func refreshFromSystem() {
        permissionStatus = permissionService.currentStatus()
        do {
            let remote = try alarmManager.alarms
            applyRemoteAlarms(remote)
        } catch {
            remoteStates = [:]
        }

        Task { @MainActor in
            await AlarmScheduleReconcileEntrypoint.reconcileAllSchedules()
        }
    }

    // MARK: - Private init wiring

    private var hasWakeUpCheckEnabledConfigurationWithNotificationRequirement: Bool {
        if defaultSharedSettings.wakeUpCheckEnabled {
            return true
        }

        return alarms.contains { alarm in
            !alarm.useDefaultSharedSettings && alarm.customSharedSettings.wakeUpCheckEnabled
        }
    }

    private func wireWakeUpCheckControllerCallbacks() {
        wakeUpCheckController.findAlarm = { [weak self] id in
            self?.alarms.first { $0.id == id }
        }
        wakeUpCheckController.findAlarmIndex = { [weak self] id in
            guard let self, let idx = self.alarms.firstIndex(where: { $0.id == id }) else { return nil }
            return (idx, self.alarms[idx])
        }
        wakeUpCheckController.allAlarmIDs = { [weak self] in
            self?.alarms.map(\.id) ?? []
        }
        wakeUpCheckController.defaultSharedSettings = { [weak self] in
            self?.defaultSharedSettings ?? .featureDefaults
        }
        wakeUpCheckController.notificationPermissionStatus = { [weak self] in
            self?.notificationPermissionStatus ?? .notDetermined
        }
        wakeUpCheckController.updateAlarm = { [weak self] id, mutate in
            guard let self, let idx = self.alarms.firstIndex(where: { $0.id == id }) else { return }
            mutate(&self.alarms[idx])
        }
        wakeUpCheckController.removeAlarm = { [weak self] id in
            self?.alarms.removeAll { $0.id == id }
        }
        wakeUpCheckController.sortAndSave = { [weak self] in
            guard let self else { return }
            self.alarms = self.sortAlarms(self.alarms)
            self.save()
        }
        wakeUpCheckController.updateLastKnownState = { [weak self] id, state in
            if let state {
                self?.lastKnownAlarmState[id] = state
            } else {
                self?.lastKnownAlarmState.removeValue(forKey: id)
            }
        }
        wakeUpCheckController.updateRemoteState = { [weak self] id, state in
            if let state {
                self?.remoteStates[id] = state
            } else {
                self?.remoteStates.removeValue(forKey: id)
            }
        }
        wakeUpCheckController.triggerReconcileForAlarm = { alarmID in
            Task { @MainActor in
                await AlarmScheduleReconcileEntrypoint.reconcileSchedule(alarmID: alarmID, forceRearm: true)
            }
        }
    }

    private func wireScheduleCoordinatorCallbacks() {
        scheduleCoordinator.findAlarm = { [weak self] id in
            self?.alarms.first { $0.id == id }
        }
        scheduleCoordinator.allAlarmIDs = { [weak self] in
            self?.alarms.map(\.id) ?? []
        }
        scheduleCoordinator.allAlarms = { [weak self] in
            self?.alarms ?? []
        }
        scheduleCoordinator.defaultSharedSettings = { [weak self] in
            self?.defaultSharedSettings ?? .featureDefaults
        }
        scheduleCoordinator.persistCommittedAlarm = { [weak self] alarm in
            self?.persistCommittedAlarm(alarm)
        }
        scheduleCoordinator.updateLastKnownState = { [weak self] id, state in
            if let state {
                self?.lastKnownAlarmState[id] = state
            } else {
                self?.lastKnownAlarmState.removeValue(forKey: id)
            }
        }
        scheduleCoordinator.updateRemoteState = { [weak self] id, state in
            if let state {
                self?.remoteStates[id] = state
            } else {
                self?.remoteStates.removeValue(forKey: id)
            }
        }
        scheduleCoordinator.removeStaleAlarms = { [weak self] staleIDs in
            guard let self else { return }
            self.alarms.removeAll { staleIDs.contains($0.id) }
            self.save()
        }
    }

    private func wireWakeUpCheckCoordinatorDependencies() {
        wakeUpCheckController.owningAlarmID = { [weak self] id in
            self?.scheduleCoordinator.owningAlarmID(for: id)
        }
        wakeUpCheckController.makeConfiguration = { [weak self] alarm, schedule, forceDisableSnooze in
            guard let self else {
                return AlarmConfigurationFactory.makeConfiguration(
                    for: alarm,
                    schedule: schedule,
                    defaultSharedSettings: .featureDefaults,
                    forceDisableSnooze: forceDisableSnooze
                )
            }
            return self.scheduleCoordinator.makeConfiguration(
                for: alarm,
                schedule: schedule,
                forceDisableSnooze: forceDisableSnooze
            )
        }
        wakeUpCheckController.scheduleAlarmWithUpdateFallback = { [weak self] id, config, isUpdate in
            guard let self else { throw CancellationError() }
            return try await self.scheduleCoordinator.scheduleAlarmWithUpdateFallback(
                id: id,
                configuration: config,
                isUpdate: isUpdate
            )
        }
    }

    private func applyLegacyWakeCheckMigration() {
        if let legacyWakeDefaults = persistence.loadLegacyDefaultWakeUpCheckDefaults() {
            self.defaultSharedSettings.wakeUpCheckEnabled = legacyWakeDefaults.enabledByDefault
            self.defaultSharedSettings.wakeUpCheckDelayMinutes = legacyWakeDefaults.clampedDelayMinutes
            persistence.saveDefaultSharedSettings(self.defaultSharedSettings)
            persistence.clearLegacyDefaultWakeUpCheckDefaults()
        }
    }
}

enum AlarmStoreError: Error {
    case permissionDenied
    case scheduleFailed
}

extension AlarmButton {
    static var snoozeButton: Self {
        AlarmButton(text: "Snooze", textColor: .black, systemImageName: "zzz")
    }

    static var stopButton: Self {
        AlarmButton(text: "Done", textColor: .white, systemImageName: "stop.circle")
    }
}
