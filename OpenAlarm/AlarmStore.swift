import AlarmKit
import AppIntents
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AlarmStore: ObservableObject {
    @Published private(set) var alarms: [UserAlarm] = []
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
    @Published private(set) var permissionStatus: AlarmPermissionStatus
    @Published private(set) var notificationPermissionStatus: NotificationPermissionStatus = .notDetermined
    @Published private(set) var remoteStates: [UUID: Alarm.State] = [:]

    private let alarmManager: AlarmManager
    private let permissionService: AlarmPermissionService
    private let notificationPermissionService: NotificationPermissionService
    private let wakeUpCheckNotificationService: WakeUpCheckNotificationService
    private let persistence: AlarmPersistence

    private var alarmUpdatesTask: Task<Void, Never>?
    private var lastKnownAlarmState: [UUID: Alarm.State] = [:]
    private(set) var wakeUpCheckController: WakeUpCheckPipelineController!
    private(set) var scheduleCoordinator: AlarmScheduleCoordinator!

    /// When temporary schedule override is active, we keep this many explicit
    /// one-shot alarms queued as fallback bridges.
    private let manualOverrideQueueDepth = AlarmSchedulePlanner.defaultManualQueueDepth

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
        self.wakeUpCheckNotificationService = wakeUpCheckNotificationService ?? WakeUpCheckNotificationService()
        self.persistence = AlarmPersistence(defaults: userDefaults)
        self.defaultSharedSettings = persistence.loadDefaultSharedSettings()
        self.defaultNapDurationMinutes = persistence.loadDefaultNapDurationMinutes()
        self.testingModeEnabled = persistence.loadTestingModeEnabled()
        self.permissionStatus = self.permissionService.currentStatus()
        self.wakeUpCheckController = WakeUpCheckPipelineController(
            persistence: persistence,
            notificationService: self.wakeUpCheckNotificationService,
            alarmManager: alarmManager
        )

        // Wire up data access callbacks for the wake-up check controller.
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
                await AlarmScheduleReconcileEntrypoint.reconcileSchedule(alarmID: alarmID)
            }
        }

        // Create schedule coordinator
        self.scheduleCoordinator = AlarmScheduleCoordinator(
            alarmManager: alarmManager,
            persistence: persistence,
            wakeUpCheckController: wakeUpCheckController,
            manualOverrideQueueDepth: manualOverrideQueueDepth
        )

        // Wire data access callbacks for the schedule coordinator.
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

        // Wire mutation callbacks for the schedule coordinator.
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
        // Wire wake-up check controller callbacks that depend on the coordinator.
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

        // Legacy migration: previous builds stored wake-check defaults separately.
        if let legacyWakeDefaults = persistence.loadLegacyDefaultWakeUpCheckDefaults() {
            self.defaultSharedSettings.wakeUpCheckEnabled = legacyWakeDefaults.enabledByDefault
            self.defaultSharedSettings.wakeUpCheckDelayMinutes = legacyWakeDefaults.clampedDelayMinutes
            persistence.saveDefaultSharedSettings(self.defaultSharedSettings)
            persistence.clearLegacyDefaultWakeUpCheckDefaults()
        }

        self.wakeUpCheckNotificationService.ensureCategoryRegistered()
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

    func handleAppOpened() {
        refreshFromSystem()

        Task { @MainActor [weak self] in
            await self?.refreshNotificationPermissionStatus()
            await AlarmScheduleReconcileEntrypoint.reconcile(trigger: .appLaunch)
        }
    }

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

    func openSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(settingsURL)
    }

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

    func createNap(from draft: NapDraft) async throws {
        try await ensureAuthorizedForScheduling()
        deleteNap()

        let now = Date.now
        let targetDate = now.addingTimeInterval(TimeInterval(draft.totalMinutes * 60))

        let nap = UserAlarm.makeNap(
            from: draft,
            defaultSharedSettings: defaultSharedSettings,
            targetDate: targetDate,
            now: now
        )

        do {
            let config = makeConfiguration(for: nap, schedule: .fixed(targetDate))
            let remoteAlarm = try await alarmManager.schedule(id: nap.id, configuration: config)
            lastKnownAlarmState[nap.id] = remoteAlarm.state
            remoteStates[nap.id] = remoteAlarm.state
            alarms.append(nap)
            alarms = sortAlarms(alarms)
            save()
        } catch {
            throw AlarmStoreError.scheduleFailed
        }
    }

    func pauseNap() {
        guard let napIndex = alarms.firstIndex(where: { $0.isNap }),
              !alarms[napIndex].isPaused,
              let target = alarms[napIndex].fixedTriggerDate else {
            return
        }

        let remaining = max(1, target.timeIntervalSinceNow)

        do {
            try alarmManager.cancel(id: alarms[napIndex].id)
        } catch {
            return
        }

        alarms[napIndex].pausedRemainingSeconds = remaining
        alarms[napIndex].updatedAt = .now
        save()
        remoteStates.removeValue(forKey: alarms[napIndex].id)
        lastKnownAlarmState[alarms[napIndex].id] = .paused
    }

    func resumeNap() async {
        guard let napIndex = alarms.firstIndex(where: { $0.isNap }),
              let pausedRemaining = alarms[napIndex].pausedRemainingSeconds else {
            return
        }

        let napID = alarms[napIndex].id
        let nextTarget = Date.now.addingTimeInterval(max(1, pausedRemaining))

        do {
            var updatedNap = alarms[napIndex]
            updatedNap.fixedTriggerDate = nextTarget
            updatedNap.pausedRemainingSeconds = nil
            updatedNap.updatedAt = .now
            let config = makeConfiguration(for: updatedNap, schedule: .fixed(nextTarget))
            let remoteAlarm = try await alarmManager.schedule(id: napID, configuration: config)
            alarms[napIndex] = updatedNap
            save()
            remoteStates[napID] = remoteAlarm.state
            lastKnownAlarmState[napID] = remoteAlarm.state
        } catch {
            // Keep paused state when resume fails.
        }
    }

    func deleteNap() {
        let napAlarms = alarms.filter { $0.isNap }
        guard !napAlarms.isEmpty else {
            return
        }

        var wakeSessionsChanged = false

        // Singleton hardening: remove ALL nap entries, not just the first.
        for nap in napAlarms {
            let napID = nap.id
            try? alarmManager.stop(id: napID)
            try? alarmManager.cancel(id: napID)

            persistence.removePendingIDFromAll(napID)

            if wakeUpCheckController.removeSession(for: napID) != nil {
                wakeSessionsChanged = true
            }

            remoteStates.removeValue(forKey: napID)
            lastKnownAlarmState.removeValue(forKey: napID)
        }

        alarms.removeAll { $0.isNap }

        if wakeSessionsChanged {
            wakeUpCheckController.persistSessions()
        }

        save()
    }

    func createAlarm(from draft: AlarmDraft) async throws {
        try await upsertAlarm(existingAlarm: nil, draft: draft)
    }

    func updateAlarm(_ alarm: UserAlarm, with draft: AlarmDraft, clearNextOverride: Bool = false) async throws {
        try await upsertAlarm(existingAlarm: alarm, draft: draft, clearNextOverride: clearNextOverride)
    }

    func updateNextAlarmOccurrence(_ alarm: UserAlarm, with draft: AlarmDraft) async throws {
        try await ensureAuthorizedForScheduling()

        guard alarm.isRepeating else {
            try await updateAlarm(alarm, with: draft)
            return
        }

        guard let index = alarms.firstIndex(where: { $0.id == alarm.id }) else {
            throw AlarmStoreError.scheduleFailed
        }

        let now = Date.now
        var current = alarms[index]

        let timeComponents = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: draft.time)
        let overrideHour = timeComponents.hour ?? current.hour
        let overrideMinute = timeComponents.minute ?? current.minute

        guard let nextOverrideDate = nextOverrideOccurrenceDate(
            for: current,
            overrideHour: overrideHour,
            overrideMinute: overrideMinute,
            after: now
        ) else {
            throw AlarmStoreError.scheduleFailed
        }

        guard let activation = AlarmSchedulePlanner.activateTemporaryOverride(
            canonicalSchedule: current.canonicalScheduleSpec,
            intent: .modifyNext(triggerDate: nextOverrideDate),
            now: now,
            manualQueueDepth: manualOverrideQueueDepth
        ) else {
            throw AlarmStoreError.scheduleFailed
        }

        let staleManualIDs = Set(current.manualScheduleQueue.map(\.id))

        applyTemporaryScheduleOverrideActivation(
            activation,
            to: &current,
            isEnabled: true,
            nextTriggerOverrideDate: nextOverrideDate,
            skipNextUntilDate: nil,
            updatedAt: now
        )
        current.snoozeCount = 0

        persistCommittedAlarm(current)

        await cancelRuntimeAlarms(ids: staleManualIDs.subtracting(Set(current.manualScheduleQueue.map(\.id))))
        await AlarmScheduleReconcileEntrypoint.reconcileSchedule(alarmID: current.id)
    }

    func setAlarmEnabled(_ alarm: UserAlarm, enabled: Bool, skipNext: Bool?) async throws {
        if enabled || skipNext == true {
            try await ensureAuthorizedForScheduling()
        }

        guard let index = alarms.firstIndex(where: { $0.id == alarm.id }) else {
            return
        }

        let now = Date.now
        var updatedAlarm = alarms[index]
        let staleManualIDs = Set(updatedAlarm.manualScheduleQueue.map(\.id))

        if enabled {
            updatedAlarm.clearTemporaryScheduleOverride(
                restoreEnabledState: true,
                clearManualQueue: true,
                updatedAt: now
            )
        } else if updatedAlarm.isRepeating,
                  skipNext == true {
            guard let activation = AlarmSchedulePlanner.activateTemporaryOverride(
                canonicalSchedule: updatedAlarm.canonicalScheduleSpec,
                intent: .disableNext,
                now: now,
                manualQueueDepth: manualOverrideQueueDepth
            ) else {
                throw AlarmStoreError.scheduleFailed
            }

            // Disable-next and modify-next are mutually exclusive by construction:
            // this call fully replaces temporary scheduling mode in one write.
            applyTemporaryScheduleOverrideActivation(
                activation,
                to: &updatedAlarm,
                isEnabled: false,
                nextTriggerOverrideDate: nil,
                skipNextUntilDate: activation.overrideState.skippedCanonicalDate,
                updatedAt: now
            )
        } else {
            // Full disable clears all temporary scheduling state.
            updatedAlarm.clearTemporaryScheduleOverride(
                restoreEnabledState: false,
                clearManualQueue: true,
                updatedAt: now
            )

            if wakeUpCheckController.removeSession(for: updatedAlarm.id) != nil {
                wakeUpCheckController.persistSessions()
            }

            persistence.removePendingIDFromAll(updatedAlarm.id)
        }

        updatedAlarm.lifecycleState = .scheduled

        persistCommittedAlarm(updatedAlarm)

        await cancelRuntimeAlarms(ids: staleManualIDs.subtracting(Set(updatedAlarm.manualScheduleQueue.map(\.id))))
        await AlarmScheduleReconcileEntrypoint.reconcileSchedule(alarmID: updatedAlarm.id)
    }

    func deleteAlarm(_ alarm: UserAlarm) {
        try? alarmManager.cancel(id: alarm.id)

        for manual in alarm.manualScheduleQueue {
            try? alarmManager.stop(id: manual.id)
            try? alarmManager.cancel(id: manual.id)
            lastKnownAlarmState.removeValue(forKey: manual.id)
            remoteStates.removeValue(forKey: manual.id)
        }

        alarms.removeAll { $0.id == alarm.id }
        remoteStates.removeValue(forKey: alarm.id)
        lastKnownAlarmState.removeValue(forKey: alarm.id)

        if wakeUpCheckController.removeSession(for: alarm.id) != nil {
            wakeUpCheckController.persistSessions()
        }

        persistence.removePendingIDFromAll(alarm.id)

        save()
    }

    func scheduleTryOut(sharedSettings: SharedAlarmSettings, after seconds: TimeInterval) async throws {
        let draft = AlarmDraft(
            name: "",
            time: .now,
            repeatDays: [],
            deleteAfterUse: true,
            useDefaultSharedSettings: false,
            customSharedSettings: sharedSettings
        )
        try await scheduleTryOut(from: draft, after: seconds)
    }

    func scheduleTryOut(from draft: AlarmDraft, after seconds: TimeInterval) async throws {
        try await ensureAuthorizedForScheduling()

        // Keep only one active try-out alarm at a time.
        let existingTryOuts = alarms.filter { $0.isTryOut }
        for tryOut in existingTryOuts {
            deleteAlarm(tryOut)
        }

        let tryOutID = UUID()

        var trialDraft = draft
        let trialSharedSettings = draft.resolvedSharedSettings(defaults: defaultSharedSettings)
        trialDraft.useDefaultSharedSettings = false
        trialDraft.customSharedSettings = trialSharedSettings

        var tryOutAlarm = trialDraft.toUserAlarm(
            id: tryOutID,
            existingCreatedAt: nil,
            defaultSharedSettings: defaultSharedSettings,
            existingSnoozeCount: 0,
            alarmType: .tryOut
        )
        let trialDate = Date.now.addingTimeInterval(seconds)
        tryOutAlarm.fixedTriggerDate = trialDate
        AlarmTypePolicy.normalizeOnWrite(&tryOutAlarm)

        let config = makeConfiguration(for: tryOutAlarm, schedule: .fixed(trialDate))
        _ = try await alarmManager.schedule(id: tryOutID, configuration: config)

        persistCommittedAlarm(tryOutAlarm)
    }

    func lifecycleLabel(for state: AlarmLifecycleState) -> LocalizedStringKey {
        switch state {
        case .scheduled:
            return L10n.alarmStateScheduled
        case .alerting:
            return L10n.alarmStateAlerting
        case .awaitingWakeCheck:
            return L10n.alarmStateAwaitingWakeCheck
        case .completed:
            return L10n.alarmStateCompleted
        }
    }

    func permissionStatusLabel() -> LocalizedStringKey {
        switch permissionStatus {
        case .authorized:
            return L10n.settingsPermissionAuthorized
        case .notDetermined:
            return L10n.settingsPermissionNotDetermined
        case .denied:
            return L10n.settingsPermissionDenied
        }
    }

    func userFacingErrorMessage(for error: Error) -> LocalizedStringKey {
        guard let storeError = error as? AlarmStoreError else {
            return L10n.alarmEditorErrorGeneric
        }

        switch storeError {
        case .permissionDenied:
            return L10n.alarmEditorErrorPermissionDenied
        case .scheduleFailed:
            return L10n.alarmEditorErrorGeneric
        }
    }

    private var hasWakeUpCheckEnabledConfigurationWithNotificationRequirement: Bool {
        if defaultSharedSettings.wakeUpCheckEnabled {
            return true
        }

        return alarms.contains { alarm in
            !alarm.useDefaultSharedSettings && alarm.customSharedSettings.wakeUpCheckEnabled
        }
    }

    private func scheduleAlarmWithUpdateFallback(
        id: UUID,
        configuration: AlarmManager.AlarmConfiguration<OpenAlarmMetadata>,
        isUpdate: Bool
    ) async throws -> Alarm {
        try await scheduleCoordinator.scheduleAlarmWithUpdateFallback(
            id: id,
            configuration: configuration,
            isUpdate: isUpdate
        )
    }

    private func nextOccurrenceDate(
        in weekdays: [AlarmWeekday],
        hour: Int,
        minute: Int,
        after referenceDate: Date
    ) -> Date? {
        let calendar = Calendar.autoupdatingCurrent
        let searchStart = referenceDate.addingTimeInterval(1)

        let candidates = weekdays.compactMap { weekday -> Date? in
            var components = DateComponents()
            components.weekday = weekday.rawValue
            components.hour = hour
            components.minute = minute
            components.second = 0

            return calendar.nextDate(
                after: searchStart,
                matching: components,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            )
        }

        return candidates.min()
    }

    private func nextOverrideOccurrenceDate(
        for alarm: UserAlarm,
        overrideHour: Int,
        overrideMinute: Int,
        after referenceDate: Date
    ) -> Date? {
        let calendar = Calendar.autoupdatingCurrent

        guard let baselineNext = nextOccurrenceDate(
            in: alarm.sortedRepeatDays,
            hour: alarm.hour,
            minute: alarm.minute,
            after: referenceDate
        ) else {
            return nil
        }

        var dayComponents = calendar.dateComponents([.year, .month, .day], from: baselineNext)
        dayComponents.hour = overrideHour
        dayComponents.minute = overrideMinute
        dayComponents.second = 0

        guard let candidateOnBaselineDay = calendar.date(from: dayComponents) else {
            return nil
        }

        if candidateOnBaselineDay > referenceDate {
            return candidateOnBaselineDay
        }

        return nextOccurrenceDate(
            in: alarm.sortedRepeatDays,
            hour: overrideHour,
            minute: overrideMinute,
            after: baselineNext
        )
    }

    private func nextPlannedTriggerDate(for alarm: UserAlarm, after referenceDate: Date) -> Date? {
        if let overrideDate = alarm.nextTriggerOverrideDate, overrideDate > referenceDate {
            return overrideDate
        }

        if alarm.isRepeating {
            return nextOccurrenceDate(
                in: alarm.sortedRepeatDays,
                hour: alarm.hour,
                minute: alarm.minute,
                after: referenceDate
            )
        }

        let calendar = Calendar.autoupdatingCurrent
        var components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        components.hour = alarm.hour
        components.minute = alarm.minute
        components.second = 0

        guard let todayCandidate = calendar.date(from: components) else {
            return nil
        }

        if todayCandidate > referenceDate {
            return todayCandidate
        }

        return calendar.date(byAdding: .day, value: 1, to: todayCandidate)
    }

    private func upsertAlarm(existingAlarm: UserAlarm?, draft: AlarmDraft, clearNextOverride: Bool = false) async throws {
        try await ensureAuthorizedForScheduling()

        let now = Date.now
        let id = existingAlarm?.id ?? UUID()

        var nextAlarm = draft.toUserAlarm(
            id: id,
            existingCreatedAt: existingAlarm?.createdAt,
            defaultSharedSettings: defaultSharedSettings,
            existingScheduleConfigReferenceID: existingAlarm?.scheduleConfigReferenceID,
            existingNextTriggerOverrideDate: existingAlarm?.nextTriggerOverrideDate,
            existingIsEnabled: existingAlarm?.isEnabled ?? true,
            existingSkipNextUntilDate: existingAlarm?.skipNextUntilDate,
            existingSnoozeCount: existingAlarm?.snoozeCount,
            existingTemporaryScheduleOverride: existingAlarm?.temporaryScheduleOverride,
            existingManualScheduleQueue: existingAlarm?.manualScheduleQueue ?? []
        )

        let staleManualIDs = Set(existingAlarm?.manualScheduleQueue.map(\.id) ?? [])

        let canonicalScheduleChanged: Bool = if let existingAlarm {
            AlarmSchedulePlanner.shouldClearTemporaryOverride(
                previous: AlarmCanonicalScheduleSignature(spec: existingAlarm.canonicalScheduleSpec),
                next: AlarmCanonicalScheduleSignature(spec: nextAlarm.canonicalScheduleSpec)
            )
        } else {
            false
        }

        let shouldClearOverride = clearNextOverride || canonicalScheduleChanged || !nextAlarm.isRepeating

        if shouldClearOverride {
            let shouldRestoreEnabledState = existingAlarm?.temporaryScheduleOverride?.kind == .disableNext

            nextAlarm.clearTemporaryScheduleOverride(
                restoreEnabledState: shouldRestoreEnabledState ? true : nil,
                clearManualQueue: true,
                updatedAt: now
            )
        } else {
            nextAlarm.updatedAt = now
        }

        let wakeCheckEnabled = nextAlarm.resolvedSharedSettings(defaults: defaultSharedSettings).wakeUpCheckEnabled
        if !wakeCheckEnabled {
            if wakeUpCheckController.removeSession(for: id) != nil {
                wakeUpCheckController.persistSessions()
            }

            persistence.removePendingID(id, from: .wakeStart)
        }

        persistCommittedAlarm(nextAlarm)

        await cancelRuntimeAlarms(ids: staleManualIDs.subtracting(Set(nextAlarm.manualScheduleQueue.map(\.id))))
        await AlarmScheduleReconcileEntrypoint.reconcileSchedule(alarmID: id)
    }

    private func ensureAuthorizedForScheduling() async throws {
        let status = await requestPermissionIfNeeded()
        guard status == .authorized else {
            throw AlarmStoreError.permissionDenied
        }
    }

    private func rescheduleAlarmsUsingDefaultSharedSettings() async {
        for alarm in alarms where alarm.useDefaultSharedSettings {
            await AlarmScheduleReconcileEntrypoint.reconcileSchedule(alarmID: alarm.id)
        }
    }

    private func rescheduleActiveNap() async {
        guard let napIndex = alarms.firstIndex(where: { $0.isNap }),
              !alarms[napIndex].isPaused,
              let target = alarms[napIndex].fixedTriggerDate else {
            return
        }

        let nap = alarms[napIndex]
        do {
            let config = makeConfiguration(for: nap, schedule: .fixed(target))
            let remote = try await alarmManager.schedule(id: nap.id, configuration: config)
            lastKnownAlarmState[nap.id] = remote.state
            remoteStates[nap.id] = remote.state
        } catch {
            // Best effort only; next refresh can reconcile state.
        }
    }

    private func buildManualQueueEntries(
        triggerDates: [Date],
        restoreAnchorDate: Date,
        configReferenceID: UUID,
        overrideDate: Date?
    ) -> [AlarmManualScheduleEntry] {
        triggerDates
            .sorted()
            .map { triggerDate in
                AlarmManualScheduleEntry(
                    id: UUID(),
                    triggerDate: triggerDate,
                    restoreAnchorDate: restoreAnchorDate,
                    configReferenceID: configReferenceID,
                    role: (overrideDate != nil && triggerDate == overrideDate) ? .overrideTrigger : .canonicalBridge
                )
            }
    }

    private func applyTemporaryScheduleOverrideActivation(
        _ activation: AlarmTemporaryOverrideActivationPlan,
        to alarm: inout UserAlarm,
        isEnabled: Bool,
        nextTriggerOverrideDate: Date?,
        skipNextUntilDate: Date?,
        updatedAt: Date
    ) {
        alarm.isEnabled = isEnabled
        alarm.nextTriggerOverrideDate = nextTriggerOverrideDate
        alarm.skipNextUntilDate = skipNextUntilDate
        alarm.temporaryScheduleOverride = activation.overrideState
        alarm.manualScheduleQueue = buildManualQueueEntries(
            triggerDates: activation.manualTriggerDates,
            restoreAnchorDate: activation.overrideState.restoreAnchorDate,
            configReferenceID: alarm.scheduleConfigReferenceID,
            overrideDate: activation.overrideState.overrideDate
        )
        alarm.updatedAt = updatedAt
    }

    private func persistCommittedAlarm(_ alarm: UserAlarm) {
        if let existingIndex = alarms.firstIndex(where: { $0.id == alarm.id }) {
            alarms[existingIndex] = alarm
        } else {
            alarms.append(alarm)
        }

        alarms = sortAlarms(alarms)
        save()
    }

    private func consumeTemporaryModifyOverrideDate(
        on alarm: inout UserAlarm,
        updatedAt: Date
    ) -> Bool {
        guard var overrideState = alarm.temporaryScheduleOverride,
              overrideState.kind == .modifyNext else {
            return false
        }

        var changed = false

        if alarm.nextTriggerOverrideDate != nil {
            alarm.nextTriggerOverrideDate = nil
            changed = true
        }

        if overrideState.overrideDate != nil {
            overrideState.overrideDate = nil
            alarm.temporaryScheduleOverride = overrideState
            changed = true
        }

        if changed {
            alarm.updatedAt = updatedAt
        }

        return changed
    }

    private func cancelRuntimeAlarms(ids: Set<UUID>) async {
        await scheduleCoordinator.cancelRuntimeAlarms(ids: ids)
    }

    private func makeConfiguration(
        for alarm: UserAlarm,
        schedule: Alarm.Schedule,
        forceDisableSnooze: Bool = false,
        runtimeAlarmID: UUID? = nil,
        configReferenceID: UUID? = nil
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        scheduleCoordinator.makeConfiguration(
            for: alarm,
            schedule: schedule,
            forceDisableSnooze: forceDisableSnooze,
            runtimeAlarmID: runtimeAlarmID,
            configReferenceID: configReferenceID
        )
    }

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

    private func applyRemoteAlarms(_ incoming: [Alarm]) {
        let remoteByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        let referenceDate = Date.now

        var pendingSnoozeIDs = persistence.loadPendingSnoozeIDs()
        let originalPending = pendingSnoozeIDs

        var updated = alarms
        var changed = mergeSnoozeCountsFromPersistence(into: &updated)


        var idsToAutoDelete: Set<UUID> = []

        for index in updated.indices {
            var alarm = updated[index]

            // Temporary override mode is tracked via explicit manual one-shots.
            // Their callback transitions drive deterministic recurring restore.
            if let overrideState = alarm.temporaryScheduleOverride {
                guard !alarm.manualScheduleQueue.isEmpty else {
                    alarm.clearTemporaryScheduleOverride(
                        restoreEnabledState: true,
                        clearManualQueue: false,
                        updatedAt: referenceDate
                    )
                    alarm.lifecycleState = .scheduled
                    updated[index] = alarm
                    changed = true
                    continue
                }

                var shouldRestoreRecurring = false
                var shouldConsumeOverrideDate = false
                var hasManualAlertingState = false

                for manual in alarm.manualScheduleQueue {
                    let previousState = lastKnownAlarmState[manual.id]
                    let currentState = remoteByID[manual.id]?.state

                    if let currentState {
                        lastKnownAlarmState[manual.id] = currentState
                    } else {
                        lastKnownAlarmState.removeValue(forKey: manual.id)
                    }

                    if isSnoozeTransitionState(currentState) {
                        pendingSnoozeIDs.remove(manual.id)
                    }

                    if currentState == .alerting {
                        hasManualAlertingState = true
                    }

                    let completedFromFireTransition = previousState == .alerting && currentState != .alerting
                    let completedWhileColdStart = currentState == nil && manual.triggerDate <= referenceDate

                    if completedFromFireTransition || completedWhileColdStart {
                        if AlarmSchedulePlanner.shouldConsumeOverrideDate(
                            afterManualAlarmFiredAt: manual.triggerDate,
                            overrideState: overrideState
                        ) {
                            shouldConsumeOverrideDate = true
                        }

                        if AlarmSchedulePlanner.shouldRestoreRecurringSchedule(
                            afterManualAlarmFiredAt: manual.triggerDate,
                            overrideState: overrideState
                        ) {
                            shouldRestoreRecurring = true
                        }
                    }
                }

                if shouldConsumeOverrideDate,
                   !shouldRestoreRecurring,
                   consumeTemporaryModifyOverrideDate(on: &alarm, updatedAt: referenceDate) {
                    changed = true
                }

                if shouldRestoreRecurring {
                    for id in alarm.manualScheduleQueue.map(\.id) {
                        pendingSnoozeIDs.remove(id)
                    }

                    // Barrier B only: keep stale manual queue IDs until reconcile barrier C
                    // converges runtime and cancels those IDs deterministically.
                    alarm.clearTemporaryScheduleOverride(
                        restoreEnabledState: true,
                        clearManualQueue: false,
                        updatedAt: referenceDate
                    )
                    alarm.lifecycleState = .scheduled
                    remoteStates.removeValue(forKey: alarm.id)
                    changed = true
                } else {
                    if hasManualAlertingState {
                        if alarm.lifecycleState != .alerting {
                            alarm.lifecycleState = .alerting
                            changed = true
                        }
                        remoteStates[alarm.id] = .alerting
                    } else {
                        if alarm.lifecycleState != .scheduled {
                            alarm.lifecycleState = .scheduled
                            changed = true
                        }
                        remoteStates[alarm.id] = .scheduled
                    }
                }

                updated[index] = alarm
                continue
            }

            let alarmID = alarm.id
            let previousState = lastKnownAlarmState[alarmID]
            let currentState = remoteByID[alarmID]?.state

            if let currentState {
                lastKnownAlarmState[alarmID] = currentState
                remoteStates[alarmID] = currentState
            } else {
                lastKnownAlarmState.removeValue(forKey: alarmID)
                remoteStates.removeValue(forKey: alarmID)
            }

            if isSnoozeTransitionState(currentState) {
                pendingSnoozeIDs.remove(alarmID)
            }

            if previousState == .alerting, currentState != .alerting {
                applyPostAlertTransition(
                    alarm: &alarm,
                    previousState: previousState,
                    currentState: currentState,
                    pendingSnoozeIDs: &pendingSnoozeIDs,
                    idsToAutoDelete: &idsToAutoDelete,
                    changed: &changed
                )
                updated[index] = alarm
                continue
            }

            _ = applyRecurringScheduleReconciliation(
                alarm: &alarm,
                previousState: previousState,
                currentState: currentState,
                changed: &changed
            )

            guard let currentState else {
                updated[index] = alarm
                continue
            }

            switch currentState {
            case .alerting:
                if let session = wakeUpCheckController.sessionsByAlarmID[alarmID],
                   session.status != .deadlineFired {
                    wakeUpCheckController.setSession(
                        WakeUpCheckStateMachine.markDeadlineFired(session, now: referenceDate),
                        for: alarmID
                    )
                    wakeUpCheckController.persistSessions()
                }

                if alarm.lifecycleState != .alerting {
                    alarm.lifecycleState = .alerting
                    changed = true
                }
            case .scheduled, .countdown, .paused:
                if alarm.lifecycleState != .scheduled {
                    alarm.lifecycleState = .scheduled
                    changed = true
                }
            @unknown default:
                break
            }

            updated[index] = alarm
        }

        if !idsToAutoDelete.isEmpty {
            for id in idsToAutoDelete {
                try? alarmManager.cancel(id: id)
                remoteStates.removeValue(forKey: id)
                lastKnownAlarmState.removeValue(forKey: id)
                pendingSnoozeIDs.remove(id)

                persistence.removePendingID(id, from: .wakeStart)
                persistence.removePendingID(id, from: .wakeConfirm)

                wakeUpCheckController.removeSession(for: id)
            }
            wakeUpCheckController.persistSessions()
            updated.removeAll { idsToAutoDelete.contains($0.id) }
            changed = true
        }

        if handleActiveNap(remoteByID: remoteByID, pendingSnoozeIDs: &pendingSnoozeIDs, updated: &updated) {
            changed = true
        }

        if changed {
            alarms = sortAlarms(updated)
            save()
        }

        if pendingSnoozeIDs != originalPending {
            persistence.savePendingSnoozeIDs(pendingSnoozeIDs)
        }
    }

    private func applyPostAlertTransition(
        alarm: inout UserAlarm,
        previousState: Alarm.State?,
        currentState: Alarm.State?,
        pendingSnoozeIDs: inout Set<UUID>,
        idsToAutoDelete: inout Set<UUID>,
        changed: inout Bool
    ) {
        // If a snooze action just ran, keep alarm in scheduled state and skip completion.
        if pendingSnoozeIDs.contains(alarm.id) {
            if alarm.lifecycleState != .scheduled {
                alarm.lifecycleState = .scheduled
                changed = true
            }
            return
        }

        let hadSnoozes = alarm.snoozeCount > 0

        // Snooze transition path should remain active and not mark completion.
        let effectiveSharedSettings = alarm.resolvedSharedSettings(defaults: defaultSharedSettings)
        let wakeCheckEnabled = effectiveSharedSettings.wakeUpCheckEnabled

        if effectiveSharedSettings.snoozeEnabled,
           hadSnoozes,
           isSnoozeTransitionState(currentState) {
            if alarm.lifecycleState != .scheduled {
                alarm.lifecycleState = .scheduled
                changed = true
            }
            return
        }

        if hadSnoozes {
            alarm.snoozeCount = 0
            alarm.updatedAt = .now
            changed = true
        }

        if alarm.isRepeating {
            if alarm.temporaryScheduleOverride != nil {
                if alarm.lifecycleState != .scheduled {
                    alarm.lifecycleState = .scheduled
                    changed = true
                }
                return
            }

            let reconciliationOperations = applyRecurringScheduleReconciliation(
                alarm: &alarm,
                previousState: previousState,
                currentState: currentState,
                changed: &changed,
                allowRecurringRestore: !wakeCheckEnabled
            )
            let scheduledRecurringRestore = reconciliationOperations.contains(.scheduleRecurringRestore)

            if hadSnoozes,
               alarm.isEnabled,
               !wakeCheckEnabled,
               !scheduledRecurringRestore {
                scheduleCoordinator.scheduleRepeatRestore(for: alarm)
            }

            if wakeCheckEnabled {
                if alarm.lifecycleState != .scheduled {
                    alarm.lifecycleState = .scheduled
                    changed = true
                }
                return
            }

            if alarm.lifecycleState != .scheduled {
                alarm.lifecycleState = .scheduled
                changed = true
            }
            return
        }

        if wakeCheckEnabled {
            if alarm.lifecycleState != .scheduled {
                alarm.lifecycleState = .scheduled
                changed = true
            }
            return
        }

        if alarm.lifecycleState != .completed {
            alarm.lifecycleState = .completed
            changed = true
        }

        if alarm.deleteAfterUse {
            idsToAutoDelete.insert(alarm.id)
        } else if alarm.isEnabled {
            alarm.isEnabled = false
            alarm.skipNextUntilDate = nil
            alarm.updatedAt = .now
            changed = true
        }
    }

    private func applyRecurringScheduleReconciliation(
        alarm: inout UserAlarm,
        previousState: Alarm.State?,
        currentState: Alarm.State?,
        changed: inout Bool,
        allowRecurringRestore: Bool = true,
        referenceDate: Date = .now
    ) -> [AlarmScheduleOperation] {
        let desiredPlan = AlarmScheduleDesiredPlan(
            isRepeating: alarm.isRepeating,
            mode: desiredScheduleMode(for: alarm),
            nextTriggerOverrideDate: alarm.nextTriggerOverrideDate
        )
        let actualState = AlarmScheduleActualState(
            previous: scheduleRemoteState(for: previousState),
            current: scheduleRemoteState(for: currentState)
        )

        let operations = AlarmScheduleReconciler.reconcile(
            desired: desiredPlan,
            actual: actualState,
            now: referenceDate
        )

        for operation in operations {
            switch operation {
            case .clearTemporarySkipAndEnableRecurring:
                if !alarm.isEnabled || alarm.skipNextUntilDate != nil {
                    alarm.isEnabled = true
                    alarm.skipNextUntilDate = nil
                    alarm.updatedAt = referenceDate
                    changed = true
                }

            case .clearTemporaryOneShot:
                if alarm.nextTriggerOverrideDate != nil {
                    alarm.nextTriggerOverrideDate = nil
                    alarm.updatedAt = referenceDate
                    changed = true
                }

            case .scheduleRecurringRestore:
                if allowRecurringRestore,
                   alarm.isEnabled {
                    scheduleCoordinator.scheduleRepeatRestore(for: alarm)
                }
            }
        }

        return operations
    }

    private func desiredScheduleMode(for alarm: UserAlarm) -> AlarmScheduleDesiredMode {
        if !alarm.isEnabled,
           let skipUntil = alarm.skipNextUntilDate {
            return .temporarySkip(until: skipUntil)
        }

        if let overrideDate = alarm.nextTriggerOverrideDate {
            return .temporaryOneShot(triggerDate: overrideDate)
        }

        return alarm.isEnabled ? .recurring : .disabled
    }

    private func scheduleRemoteState(for state: Alarm.State?) -> AlarmScheduleRemoteState {
        guard let state else {
            return .missing
        }

        switch state {
        case .scheduled:
            return .scheduled
        case .countdown:
            return .countdown
        case .paused:
            return .paused
        case .alerting:
            return .alerting
        @unknown default:
            return .missing
        }
    }

    @discardableResult
    /// Reconciles the active nap alarm's state against remote AlarmKit state.
    /// Handles remote-initiated pause/resume and expiry cleanup.
    /// Returns true if `updated` was mutated.
    private func handleActiveNap(
        remoteByID: [UUID: Alarm],
        pendingSnoozeIDs: inout Set<UUID>,
        updated: inout [UserAlarm]
    ) -> Bool {
        guard let napIndex = updated.firstIndex(where: { $0.isNap }) else {
            return false
        }

        var nap = updated[napIndex]
        let napID = nap.id
        let previousState = lastKnownAlarmState[napID]
        let currentState = remoteByID[napID]?.state

        if let currentState {
            lastKnownAlarmState[napID] = currentState
            remoteStates[napID] = currentState
        } else {
            remoteStates.removeValue(forKey: napID)
            if nap.isPaused {
                lastKnownAlarmState[napID] = .paused
            } else {
                lastKnownAlarmState.removeValue(forKey: napID)
            }
        }

        // Nap completed (alert → non-alert transition)
        if previousState == .alerting, currentState != .alerting {
            pendingSnoozeIDs.remove(napID)
            remoteStates.removeValue(forKey: napID)
            lastKnownAlarmState.removeValue(forKey: napID)
            updated.remove(at: napIndex)
            return true
        }

        // Remote-initiated pause detection
        if currentState == .paused {
            if nap.pausedRemainingSeconds == nil, let target = nap.fixedTriggerDate {
                nap.pausedRemainingSeconds = max(1, target.timeIntervalSinceNow)
                nap.updatedAt = .now
                updated[napIndex] = nap
                return true
            }
            return false
        }

        // Remote-initiated resume detection
        if nap.isPaused, (currentState == .countdown || currentState == .scheduled) {
            nap.pausedRemainingSeconds = nil
            if let target = nap.fixedTriggerDate {
                nap.fixedTriggerDate = max(Date.now, target)
            }
            nap.updatedAt = .now
            updated[napIndex] = nap
            return true
        }

        // Nap expired (target passed, no remote alarm left)
        if !nap.isPaused, currentState == nil,
           let target = nap.fixedTriggerDate, target <= .now {
            pendingSnoozeIDs.remove(napID)
            remoteStates.removeValue(forKey: napID)
            lastKnownAlarmState.removeValue(forKey: napID)
            updated.remove(at: napIndex)
            return true
        }

        return false
    }

    private func isSnoozeTransitionState(_ state: Alarm.State?) -> Bool {
        state == .scheduled || state == .countdown || state == .paused
    }

    private func mergeSnoozeCountsFromPersistence(into alarms: inout [UserAlarm]) -> Bool {
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

    private func sortAlarms(_ alarms: [UserAlarm]) -> [UserAlarm] {
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

    private func load() {
        alarms = sortAlarms(persistence.loadUserAlarms())
    }

    private func save() {
        persistence.saveUserAlarms(alarms)
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
