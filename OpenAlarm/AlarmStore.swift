import AlarmKit
import AppIntents
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AlarmStore: ObservableObject, AlarmScheduleReconcileHandling {
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
    private let userDefaults: UserDefaults

    private var alarmUpdatesTask: Task<Void, Never>?
    private var lastKnownAlarmState: [UUID: Alarm.State] = [:]
    private var pendingRepeatRestores: Set<UUID> = []
    private var wakeUpCheckSessionsByAlarmID: [UUID: WakeUpCheckSessionState] = [:]

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
        self.userDefaults = userDefaults
        self.defaultSharedSettings = AlarmPersistence.loadDefaultSharedSettings(from: userDefaults)
        self.defaultNapDurationMinutes = AlarmPersistence.loadDefaultNapDurationMinutes(from: userDefaults)
        self.testingModeEnabled = AlarmPersistence.loadTestingModeEnabled(from: userDefaults)
        self.permissionStatus = self.permissionService.currentStatus()
        self.wakeUpCheckSessionsByAlarmID = Dictionary(uniqueKeysWithValues: AlarmPersistence.loadWakeUpCheckSessions(from: userDefaults).map { ($0.alarmID, $0) })

        // Legacy migration: previous builds stored wake-check defaults separately.
        if let legacyWakeDefaults = AlarmPersistence.loadLegacyDefaultWakeUpCheckDefaults(from: userDefaults) {
            self.defaultSharedSettings.wakeUpCheckEnabled = legacyWakeDefaults.enabledByDefault
            self.defaultSharedSettings.wakeUpCheckDelayMinutes = legacyWakeDefaults.clampedDelayMinutes
            AlarmPersistence.saveDefaultSharedSettings(self.defaultSharedSettings, to: userDefaults)
            AlarmPersistence.clearLegacyDefaultWakeUpCheckDefaults(from: userDefaults)
        }

        self.wakeUpCheckNotificationService.ensureCategoryRegistered()
        AlarmScheduleReconcileEntrypoint.register(handler: self)

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
        AlarmPersistence.saveDefaultSharedSettings(settings, to: userDefaults)

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
            AlarmPersistence.saveDefaultSharedSettings(defaults, to: userDefaults)
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

        clearAllWakeUpCheckSessions(restoreSchedules: true)
    }

    func updateTestingModeEnabled(_ enabled: Bool) {
        guard testingModeEnabled != enabled else {
            return
        }

        testingModeEnabled = enabled
        AlarmPersistence.saveTestingModeEnabled(enabled, to: userDefaults)
    }

    func updateDefaultNapDurationMinutes(_ minutes: Int) {
        let next = max(1, minutes)
        guard defaultNapDurationMinutes != next else {
            return
        }

        defaultNapDurationMinutes = next
        AlarmPersistence.saveDefaultNapDurationMinutes(next, to: userDefaults)
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

        var pendingSnooze = AlarmPersistence.loadPendingSnoozeIDs(from: userDefaults)
        var pendingWakeStarts = AlarmPersistence.loadPendingWakeUpCheckStartIDs(from: userDefaults)
        var pendingWakeConfirm = AlarmPersistence.loadPendingWakeUpCheckConfirmIDs(from: userDefaults)
        var wakeSessionsChanged = false

        // Singleton hardening: remove ALL nap entries, not just the first.
        for nap in napAlarms {
            let napID = nap.id
            try? alarmManager.stop(id: napID)
            try? alarmManager.cancel(id: napID)

            _ = pendingSnooze.remove(napID)
            _ = pendingWakeStarts.remove(napID)
            _ = pendingWakeConfirm.remove(napID)

            if let session = wakeUpCheckSessionsByAlarmID.removeValue(forKey: napID) {
                wakeUpCheckNotificationService.cancel(notificationID: session.notificationID)
                wakeSessionsChanged = true
            }

            remoteStates.removeValue(forKey: napID)
            lastKnownAlarmState.removeValue(forKey: napID)
        }

        alarms.removeAll { $0.isNap }

        AlarmPersistence.savePendingSnoozeIDs(pendingSnooze, to: userDefaults)
        AlarmPersistence.savePendingWakeUpCheckStartIDs(pendingWakeStarts, to: userDefaults)
        AlarmPersistence.savePendingWakeUpCheckConfirmIDs(pendingWakeConfirm, to: userDefaults)
        if wakeSessionsChanged {
            persistWakeUpCheckSessions()
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
            clearTemporaryScheduleOverrideState(
                on: &updatedAlarm,
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
            clearTemporaryScheduleOverrideState(
                on: &updatedAlarm,
                restoreEnabledState: false,
                clearManualQueue: true,
                updatedAt: now
            )

            if let session = wakeUpCheckSessionsByAlarmID.removeValue(forKey: updatedAlarm.id) {
                wakeUpCheckNotificationService.cancel(notificationID: session.notificationID)
                persistWakeUpCheckSessions()
            }

            var pending = AlarmPersistence.loadPendingSnoozeIDs(from: userDefaults)
            if pending.remove(updatedAlarm.id) != nil {
                AlarmPersistence.savePendingSnoozeIDs(pending, to: userDefaults)
            }

            var pendingStarts = AlarmPersistence.loadPendingWakeUpCheckStartIDs(from: userDefaults)
            if pendingStarts.remove(updatedAlarm.id) != nil {
                AlarmPersistence.savePendingWakeUpCheckStartIDs(pendingStarts, to: userDefaults)
            }

            var pendingConfirm = AlarmPersistence.loadPendingWakeUpCheckConfirmIDs(from: userDefaults)
            if pendingConfirm.remove(updatedAlarm.id) != nil {
                AlarmPersistence.savePendingWakeUpCheckConfirmIDs(pendingConfirm, to: userDefaults)
            }
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

        if let session = wakeUpCheckSessionsByAlarmID.removeValue(forKey: alarm.id) {
            wakeUpCheckNotificationService.cancel(notificationID: session.notificationID)
            persistWakeUpCheckSessions()
        }

        var pending = AlarmPersistence.loadPendingSnoozeIDs(from: userDefaults)
        if pending.remove(alarm.id) != nil {
            AlarmPersistence.savePendingSnoozeIDs(pending, to: userDefaults)
        }

        var pendingWakeStarts = AlarmPersistence.loadPendingWakeUpCheckStartIDs(from: userDefaults)
        if pendingWakeStarts.remove(alarm.id) != nil {
            AlarmPersistence.savePendingWakeUpCheckStartIDs(pendingWakeStarts, to: userDefaults)
        }

        var pendingWakeConfirm = AlarmPersistence.loadPendingWakeUpCheckConfirmIDs(from: userDefaults)
        if pendingWakeConfirm.remove(alarm.id) != nil {
            AlarmPersistence.savePendingWakeUpCheckConfirmIDs(pendingWakeConfirm, to: userDefaults)
        }

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
        do {
            return try await alarmManager.schedule(id: id, configuration: configuration)
        } catch {
            guard isUpdate else {
                throw error
            }

            try? alarmManager.stop(id: id)
            try? alarmManager.cancel(id: id)
            return try await alarmManager.schedule(id: id, configuration: configuration)
        }
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

            clearTemporaryScheduleOverrideState(
                on: &nextAlarm,
                restoreEnabledState: shouldRestoreEnabledState ? true : nil,
                clearManualQueue: true,
                updatedAt: now
            )
        } else {
            nextAlarm.updatedAt = now
        }

        let wakeCheckEnabled = nextAlarm.resolvedSharedSettings(defaults: defaultSharedSettings).wakeUpCheckEnabled
        if !wakeCheckEnabled {
            if let session = wakeUpCheckSessionsByAlarmID.removeValue(forKey: id) {
                wakeUpCheckNotificationService.cancel(notificationID: session.notificationID)
                persistWakeUpCheckSessions()
            }

            var pendingWakeStarts = AlarmPersistence.loadPendingWakeUpCheckStartIDs(from: userDefaults)
            if pendingWakeStarts.remove(id) != nil {
                AlarmPersistence.savePendingWakeUpCheckStartIDs(pendingWakeStarts, to: userDefaults)
            }
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

    private func clearTemporaryScheduleOverrideState(
        on alarm: inout UserAlarm,
        restoreEnabledState: Bool?,
        clearManualQueue: Bool,
        updatedAt: Date
    ) {
        if let restoreEnabledState {
            alarm.isEnabled = restoreEnabledState
        }

        alarm.nextTriggerOverrideDate = nil
        alarm.skipNextUntilDate = nil
        alarm.temporaryScheduleOverride = nil

        if clearManualQueue {
            alarm.manualScheduleQueue.removeAll()
        }

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
        guard !ids.isEmpty else {
            return
        }

        for id in ids {
            try? alarmManager.stop(id: id)
            try? alarmManager.cancel(id: id)
            lastKnownAlarmState.removeValue(forKey: id)
            remoteStates.removeValue(forKey: id)
        }
    }

    private func runtimeAlarmIDsSnapshot() -> Set<UUID>? {
        guard let runtimeAlarms = try? alarmManager.alarms else {
            return nil
        }

        return Set(runtimeAlarms.map(\.id))
    }

    private func canonicalSuppressionFallbackDate(
        for alarm: UserAlarm,
        referenceDate: Date
    ) -> Date {
        let latestManualDate = alarm.manualScheduleQueue.map(\.triggerDate).max() ?? referenceDate
        let baseline = max(latestManualDate, referenceDate)
        return baseline.addingTimeInterval(60)
    }

    private func suppressCanonicalRuntimeWhileOverrideActive(
        for alarm: UserAlarm,
        referenceDate: Date
    ) async {
        try? alarmManager.stop(id: alarm.id)
        try? alarmManager.cancel(id: alarm.id)
        lastKnownAlarmState.removeValue(forKey: alarm.id)

        guard let runtimeIDs = runtimeAlarmIDsSnapshot(),
              runtimeIDs.contains(alarm.id) else {
            return
        }

        do {
            let suppressionDate = canonicalSuppressionFallbackDate(
                for: alarm,
                referenceDate: referenceDate
            )
            let config = makeConfiguration(
                for: alarm,
                schedule: .fixed(suppressionDate),
                forceDisableSnooze: true,
                runtimeAlarmID: alarm.id,
                configReferenceID: alarm.scheduleConfigReferenceID
            )
            let remote = try await scheduleAlarmWithUpdateFallback(
                id: alarm.id,
                configuration: config,
                isUpdate: true
            )
            lastKnownAlarmState[alarm.id] = remote.state
        } catch {
            lastKnownAlarmState.removeValue(forKey: alarm.id)
        }
    }

    private func scheduleManualRuntimeEntry(
        _ manual: AlarmManualScheduleEntry,
        for alarm: UserAlarm
    ) async {
        do {
            let config = makeConfiguration(
                for: alarm,
                schedule: .fixed(manual.triggerDate),
                forceDisableSnooze: true,
                runtimeAlarmID: manual.id,
                configReferenceID: manual.configReferenceID
            )
            let remote = try await scheduleAlarmWithUpdateFallback(
                id: manual.id,
                configuration: config,
                isUpdate: true
            )
            lastKnownAlarmState[manual.id] = remote.state
        } catch {
            // Best effort. Next reconciliation opportunity can recover.
        }
    }

    private func scheduleManualRuntimeQueueWithRepair(
        for alarm: UserAlarm,
        referenceDate: Date
    ) async {
        let activeManualEntries = alarm.manualScheduleQueue.filter {
            $0.triggerDate > referenceDate.addingTimeInterval(-1)
        }

        guard !activeManualEntries.isEmpty else {
            return
        }

        for manual in activeManualEntries {
            await scheduleManualRuntimeEntry(manual, for: alarm)
        }

        // AlarmKit can occasionally drop a schedule call without surfacing an
        // error; verify expected manual IDs and retry missing entries.
        for _ in 0 ..< 2 {
            guard let runtimeIDs = runtimeAlarmIDsSnapshot() else {
                return
            }

            let missingEntries = activeManualEntries.filter { !runtimeIDs.contains($0.id) }
            guard !missingEntries.isEmpty else {
                return
            }

            for manual in missingEntries {
                await scheduleManualRuntimeEntry(manual, for: alarm)
            }
        }
    }

    func reconcileSchedule(target: AlarmScheduleReconcileTarget, referenceDate: Date) async {
        await reconcileWakeUpCheckPipeline(target: target, referenceDate: referenceDate)

        switch target {
        case let .alarm(runtimeAlarmID):
            guard let alarmID = owningAlarmID(for: runtimeAlarmID) else {
                return
            }
            await reconcileSchedulingForAlarm(alarmID, referenceDate: referenceDate)

        case .allAlarms:
            await reconcileAllAlarmSchedules(referenceDate: referenceDate)
        }
    }

    private func owningAlarmID(for runtimeAlarmID: UUID) -> UUID? {
        if alarms.contains(where: { $0.id == runtimeAlarmID }) {
            return runtimeAlarmID
        }

        return alarms.first(where: { alarm in
            alarm.manualScheduleQueue.contains(where: { $0.id == runtimeAlarmID })
        })?.id
    }

    /// Reconciles every user alarm against its canonical + temporary override
    /// scheduling state. This is intentionally called at every lifecycle
    /// opportunity (app open, callback stream, refresh) to keep scheduling
    /// deterministic even after missed callbacks or device restarts.
    private func reconcileAllAlarmSchedules(referenceDate: Date = .now) async {
        // Stale one-shot cleanup: remove expired nap/tryOut alarms that have no
        // runtime entry and whose fixedTriggerDate has passed. This catches cases
        // where the app was not running when the alarm fired (cold path).
        cleanupStaleOneShotAlarms(referenceDate: referenceDate)

        let alarmIDs = alarms.map(\.id)
        for alarmID in alarmIDs {
            await reconcileSchedulingForAlarm(alarmID, referenceDate: referenceDate)
        }
    }

    /// Removes expired nap/tryOut alarms that have no runtime entry.
    ///
    /// This handles the cold-start case where a one-shot alarm fired while the
    /// app was not running, so the normal alerting→non-alerting state transition
    /// was never observed.
    private func cleanupStaleOneShotAlarms(referenceDate: Date = .now) {
        // If the runtime snapshot fails, bail out entirely rather than treating
        // the failure as an empty set—which would incorrectly mark every
        // one-shot alarm as stale and delete it.
        guard let runtimeIDs = runtimeAlarmIDsSnapshot() else {
            return
        }

        let staleOneShots = alarms.filter { alarm in
            guard alarm.alarmType == .nap || alarm.alarmType == .tryOut else {
                return false
            }
            // Paused naps/tryOuts should not be auto-deleted; the user
            // explicitly paused them and may resume later.
            guard !alarm.isPaused else {
                return false
            }
            guard let fixedDate = alarm.fixedTriggerDate, fixedDate <= referenceDate else {
                return false
            }
            // If runtime still has the alarm (e.g. alerting), don't clean up yet.
            return !runtimeIDs.contains(alarm.id)
        }

        guard !staleOneShots.isEmpty else {
            return
        }

        var pendingSnooze = AlarmPersistence.loadPendingSnoozeIDs(from: userDefaults)
        var pendingWakeStarts = AlarmPersistence.loadPendingWakeUpCheckStartIDs(from: userDefaults)
        var pendingWakeConfirm = AlarmPersistence.loadPendingWakeUpCheckConfirmIDs(from: userDefaults)
        var wakeSessionsChanged = false

        let staleIDs = Set(staleOneShots.map(\.id))

        for alarm in staleOneShots {
            let id = alarm.id
            try? alarmManager.stop(id: id)
            try? alarmManager.cancel(id: id)

            _ = pendingSnooze.remove(id)
            _ = pendingWakeStarts.remove(id)
            _ = pendingWakeConfirm.remove(id)

            if let session = wakeUpCheckSessionsByAlarmID.removeValue(forKey: id) {
                wakeUpCheckNotificationService.cancel(notificationID: session.notificationID)
                wakeSessionsChanged = true
            }

            remoteStates.removeValue(forKey: id)
            lastKnownAlarmState.removeValue(forKey: id)
        }

        alarms.removeAll { staleIDs.contains($0.id) }

        AlarmPersistence.savePendingSnoozeIDs(pendingSnooze, to: userDefaults)
        AlarmPersistence.savePendingWakeUpCheckStartIDs(pendingWakeStarts, to: userDefaults)
        AlarmPersistence.savePendingWakeUpCheckConfirmIDs(pendingWakeConfirm, to: userDefaults)
        if wakeSessionsChanged {
            persistWakeUpCheckSessions()
        }

        save()
    }

    private struct AlarmDeterministicReconcilePlan {
        var alarm: UserAlarm
        var staleManualRuntimeIDs: Set<UUID>
        var didMutatePersistedState: Bool
    }

    /// Applies scheduling state for a single alarm without consulting wake-check
    /// or snooze configuration gates.
    ///
    /// Barrier A: deterministic planning from persisted canonical+override state.
    /// Barrier B: commit planned state (`save`) before runtime side-effects.
    /// Barrier C: converge runtime toward committed state (with repair retries).
    private func reconcileSchedulingForAlarm(_ alarmID: UUID, referenceDate: Date = .now) async {
        guard let existingAlarm = alarms.first(where: { $0.id == alarmID }) else {
            return
        }

        // Barrier A — deterministic planning
        let planning = deterministicPlanningBarrier(
            for: existingAlarm,
            referenceDate: referenceDate
        )

        // Barrier B — state commit
        if planning.didMutatePersistedState {
            persistCommittedAlarm(planning.alarm)
        }

        guard let committedAlarm = alarms.first(where: { $0.id == alarmID }) else {
            return
        }

        // Barrier C — runtime convergence + repair
        await runtimeConvergenceBarrier(
            for: committedAlarm,
            staleManualRuntimeIDs: planning.staleManualRuntimeIDs,
            referenceDate: referenceDate
        )
    }

    private func deterministicPlanningBarrier(
        for alarm: UserAlarm,
        referenceDate: Date
    ) -> AlarmDeterministicReconcilePlan {
        var plannedAlarm = alarm
        var staleManualRuntimeIDs: Set<UUID> = []
        var didMutatePersistedState = false

        if let overrideState = plannedAlarm.temporaryScheduleOverride,
           plannedAlarm.isRepeating {
            let desiredDates = AlarmSchedulePlanner.desiredManualTriggerDates(
                canonicalSchedule: plannedAlarm.canonicalScheduleSpec,
                overrideState: overrideState,
                now: referenceDate,
                manualQueueDepth: manualOverrideQueueDepth
            )

            if desiredDates.isEmpty {
                staleManualRuntimeIDs.formUnion(plannedAlarm.manualScheduleQueue.map(\.id))
                clearTemporaryScheduleOverrideState(
                    on: &plannedAlarm,
                    restoreEnabledState: overrideState.kind == .disableNext ? true : nil,
                    clearManualQueue: true,
                    updatedAt: referenceDate
                )
                didMutatePersistedState = true
            } else {
                var existingByDate: [Date: AlarmManualScheduleEntry] = [:]
                for entry in plannedAlarm.manualScheduleQueue where existingByDate[entry.triggerDate] == nil {
                    existingByDate[entry.triggerDate] = entry
                }

                let rebuiltQueue: [AlarmManualScheduleEntry] = desiredDates.map { date in
                    if let existing = existingByDate[date] {
                        return existing
                    }

                    return AlarmManualScheduleEntry(
                        id: UUID(),
                        triggerDate: date,
                        restoreAnchorDate: overrideState.restoreAnchorDate,
                        configReferenceID: plannedAlarm.scheduleConfigReferenceID,
                        role: (overrideState.overrideDate != nil && date == overrideState.overrideDate) ? .overrideTrigger : .canonicalBridge
                    )
                }

                let staleIDs = Set(plannedAlarm.manualScheduleQueue.map(\.id))
                    .subtracting(Set(rebuiltQueue.map(\.id)))
                staleManualRuntimeIDs.formUnion(staleIDs)

                if rebuiltQueue != plannedAlarm.manualScheduleQueue {
                    plannedAlarm.manualScheduleQueue = rebuiltQueue
                    plannedAlarm.updatedAt = referenceDate
                    didMutatePersistedState = true
                }
            }
        } else if plannedAlarm.temporaryScheduleOverride != nil {
            // Non-repeating alarms cannot remain in temporary override mode.
            staleManualRuntimeIDs.formUnion(plannedAlarm.manualScheduleQueue.map(\.id))
            clearTemporaryScheduleOverrideState(
                on: &plannedAlarm,
                restoreEnabledState: nil,
                clearManualQueue: true,
                updatedAt: referenceDate
            )
            didMutatePersistedState = true
        }

        if plannedAlarm.temporaryScheduleOverride == nil,
           !plannedAlarm.manualScheduleQueue.isEmpty {
            staleManualRuntimeIDs.formUnion(plannedAlarm.manualScheduleQueue.map(\.id))
            plannedAlarm.manualScheduleQueue.removeAll()
            plannedAlarm.updatedAt = referenceDate
            didMutatePersistedState = true
        }

        return AlarmDeterministicReconcilePlan(
            alarm: plannedAlarm,
            staleManualRuntimeIDs: staleManualRuntimeIDs,
            didMutatePersistedState: didMutatePersistedState
        )
    }

    private func runtimeConvergenceBarrier(
        for alarm: UserAlarm,
        staleManualRuntimeIDs: Set<UUID>,
        referenceDate: Date
    ) async {
        await cancelRuntimeAlarms(ids: staleManualRuntimeIDs)

        if alarm.temporaryScheduleOverride != nil,
           alarm.isRepeating {
            // Override mode is manual-queue-only: canonical runtime must be suppressed.
            await suppressCanonicalRuntimeWhileOverrideActive(
                for: alarm,
                referenceDate: referenceDate
            )

            await scheduleManualRuntimeQueueWithRepair(
                for: alarm,
                referenceDate: referenceDate
            )

            remoteStates[alarm.id] = alarm.manualScheduleQueue.isEmpty ? nil : .scheduled
            return
        }

        if let wakeSession = wakeUpCheckSessionsByAlarmID[alarm.id] {
            // Wake-check pipeline owns runtime scheduling while a session exists.
            // Keep recurring reconciliation deterministic, but do not re-arm
            // canonical repeating schedule until confirmation completes.
            let deadlineDate = max(referenceDate.addingTimeInterval(1), wakeSession.deadlineAt)

            do {
                let config = makeConfiguration(
                    for: alarm,
                    schedule: .fixed(deadlineDate),
                    forceDisableSnooze: WakeUpCheckCoordinator.wakeCheckAlarmsDisableSnooze
                )
                let remote = try await scheduleAlarmWithUpdateFallback(
                    id: alarm.id,
                    configuration: config,
                    isUpdate: true
                )
                lastKnownAlarmState[alarm.id] = remote.state
                remoteStates[alarm.id] = remote.state
            } catch {
                // Best effort. Foreground refresh can recover.
            }

            return
        }

        // Paused naps must not be re-armed by reconcile; resume handles re-scheduling.
        if alarm.isPaused {
            return
        }

        if alarm.isEnabled {
            do {
                let resolvedSchedule = AlarmScheduleResolver.runtimeSchedule(for: alarm)
                let config = makeConfiguration(for: alarm, schedule: resolvedSchedule)
                let remote = try await scheduleAlarmWithUpdateFallback(
                    id: alarm.id,
                    configuration: config,
                    isUpdate: true
                )
                lastKnownAlarmState[alarm.id] = remote.state
                remoteStates[alarm.id] = remote.state
            } catch {
                // Best effort. Foreground refresh can recover.
            }
        } else {
            try? alarmManager.stop(id: alarm.id)
            try? alarmManager.cancel(id: alarm.id)
            lastKnownAlarmState.removeValue(forKey: alarm.id)
            remoteStates.removeValue(forKey: alarm.id)
        }
    }

    private func makeConfiguration(
        for alarm: UserAlarm,
        schedule: Alarm.Schedule,
        forceDisableSnooze: Bool = false,
        runtimeAlarmID: UUID? = nil,
        configReferenceID: UUID? = nil
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        AlarmConfigurationFactory.makeConfiguration(
            for: alarm,
            schedule: schedule,
            defaultSharedSettings: defaultSharedSettings,
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

    private func persistWakeUpCheckSessions() {
        AlarmPersistence.saveWakeUpCheckSessions(Array(wakeUpCheckSessionsByAlarmID.values), to: userDefaults)
    }

    private func wakeUpCheckPipelineAlarmIDs(
        for target: AlarmScheduleReconcileTarget,
        pendingStartIDs: Set<UUID>,
        pendingConfirmIDs: Set<UUID>
    ) -> Set<UUID> {
        switch target {
        case let .alarm(runtimeAlarmID):
            return [owningAlarmID(for: runtimeAlarmID) ?? runtimeAlarmID]

        case .allAlarms:
            var ids = Set(alarms.map(\.id))
            ids.formUnion(wakeUpCheckSessionsByAlarmID.keys)
            ids.formUnion(pendingStartIDs)
            ids.formUnion(pendingConfirmIDs)
            return ids
        }
    }

    private func reconcileWakeUpCheckPipeline(
        target: AlarmScheduleReconcileTarget,
        referenceDate: Date
    ) async {
        var pendingConfirmIDs = AlarmPersistence.loadPendingWakeUpCheckConfirmIDs(from: userDefaults)
        var pendingStartIDs = AlarmPersistence.loadPendingWakeUpCheckStartIDs(from: userDefaults)

        let targetAlarmIDs = wakeUpCheckPipelineAlarmIDs(
            for: target,
            pendingStartIDs: pendingStartIDs,
            pendingConfirmIDs: pendingConfirmIDs
        )

        if !pendingConfirmIDs.isEmpty {
            for alarmID in pendingConfirmIDs.intersection(targetAlarmIDs) {
                await completeWakeUpCheck(for: alarmID)
                pendingConfirmIDs.remove(alarmID)
                pendingStartIDs.remove(alarmID)
            }
        }

        if !pendingStartIDs.isEmpty {
            for alarmID in pendingStartIDs.intersection(targetAlarmIDs) {
                await startWakeUpCheckCycle(for: alarmID, referenceDate: referenceDate)
                pendingStartIDs.remove(alarmID)
            }
        }

        AlarmPersistence.savePendingWakeUpCheckConfirmIDs(pendingConfirmIDs, to: userDefaults)
        AlarmPersistence.savePendingWakeUpCheckStartIDs(pendingStartIDs, to: userDefaults)
    }

    private func clearAllWakeUpCheckSessions(restoreSchedules: Bool = false) {
        let affectedAlarmIDs = Set(wakeUpCheckSessionsByAlarmID.keys)

        for session in wakeUpCheckSessionsByAlarmID.values {
            wakeUpCheckNotificationService.cancel(notificationID: session.notificationID)
            try? alarmManager.stop(id: session.alarmID)
            try? alarmManager.cancel(id: session.alarmID)
        }

        wakeUpCheckSessionsByAlarmID.removeAll()
        persistWakeUpCheckSessions()

        if restoreSchedules {
            for alarmID in affectedAlarmIDs {
                Task { @MainActor in
                    await AlarmScheduleReconcileEntrypoint.reconcileSchedule(alarmID: alarmID)
                }
            }
        }

        var pendingStarts = AlarmPersistence.loadPendingWakeUpCheckStartIDs(from: userDefaults)
        if !pendingStarts.isEmpty {
            pendingStarts.removeAll()
            AlarmPersistence.savePendingWakeUpCheckStartIDs(pendingStarts, to: userDefaults)
        }

        var pendingConfirm = AlarmPersistence.loadPendingWakeUpCheckConfirmIDs(from: userDefaults)
        if !pendingConfirm.isEmpty {
            pendingConfirm.removeAll()
            AlarmPersistence.savePendingWakeUpCheckConfirmIDs(pendingConfirm, to: userDefaults)
        }
    }

    private func startWakeUpCheckCycle(
        for alarmID: UUID,
        referenceDate: Date
    ) async {
        let previousSession = wakeUpCheckSessionsByAlarmID[alarmID]

        guard let alarmIndex = alarms.firstIndex(where: { $0.id == alarmID }) else {
            if let previousSession {
                wakeUpCheckNotificationService.cancel(notificationID: previousSession.notificationID)
                wakeUpCheckSessionsByAlarmID.removeValue(forKey: alarmID)
                persistWakeUpCheckSessions()
            }
            return
        }

        let alarm = alarms[alarmIndex]
        let resolvedSettings = alarm.resolvedSharedSettings(defaults: defaultSharedSettings)
        let shouldStartCycle = WakeUpCheckCoordinator.shouldEnqueuePipelineOnStopIntent(
            wakeUpCheckEnabledForAlarm: resolvedSettings.wakeUpCheckEnabled,
            hasActiveSession: previousSession != nil
        )

        guard shouldStartCycle else {
            return
        }

        guard notificationPermissionStatus == .authorized else {
            if let previousSession {
                wakeUpCheckNotificationService.cancel(notificationID: previousSession.notificationID)
                wakeUpCheckSessionsByAlarmID.removeValue(forKey: alarmID)
                persistWakeUpCheckSessions()
            }

            await applyWakeUpCheckArmingFailureResolution(
                for: alarmID,
                referenceDate: referenceDate
            )
            return
        }

        let fallbackSnapshot = WakeUpCheckConfigSnapshot(
            checkDelayMinutes: resolvedSettings.wakeUpCheckDelayMinutes,
            responseTimeoutMinutes: resolvedSettings.wakeUpCheckResponseTimeoutMinutes
        )
        let nextSession = WakeUpCheckCoordinator.nextCycleSession(
            alarmID: alarmID,
            previousSession: previousSession,
            fallbackSnapshot: fallbackSnapshot,
            now: referenceDate,
            makeNotificationID: WakeUpCheckNotificationConstants.notificationID
        )

        if let previousSession {
            wakeUpCheckNotificationService.cancel(notificationID: previousSession.notificationID)
        }

        wakeUpCheckSessionsByAlarmID[alarmID] = nextSession
        persistWakeUpCheckSessions()

        if alarms[alarmIndex].lifecycleState != .awaitingWakeCheck {
            alarms[alarmIndex].lifecycleState = .awaitingWakeCheck
            alarms[alarmIndex].updatedAt = referenceDate
            alarms = sortAlarms(alarms)
            save()
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            guard let latestAlarm = alarms.first(where: { $0.id == alarmID }) else {
                if wakeUpCheckSessionsByAlarmID[alarmID]?.notificationID == nextSession.notificationID {
                    wakeUpCheckSessionsByAlarmID.removeValue(forKey: alarmID)
                    persistWakeUpCheckSessions()
                }
                return
            }

            var didScheduleWakeCheckNotification = false

            do {
                try await wakeUpCheckNotificationService.scheduleWakeCheckNotification(for: nextSession)
                didScheduleWakeCheckNotification = true

                let config = makeConfiguration(
                    for: latestAlarm,
                    schedule: .fixed(nextSession.deadlineAt),
                    forceDisableSnooze: WakeUpCheckCoordinator.wakeCheckAlarmsDisableSnooze
                )
                let remoteAlarm = try await scheduleAlarmWithUpdateFallback(
                    id: latestAlarm.id,
                    configuration: config,
                    isUpdate: true
                )

                lastKnownAlarmState[latestAlarm.id] = remoteAlarm.state
                remoteStates[latestAlarm.id] = remoteAlarm.state

                if let latestSession = wakeUpCheckSessionsByAlarmID[latestAlarm.id],
                   latestSession.notificationID == nextSession.notificationID {
                    wakeUpCheckSessionsByAlarmID[latestAlarm.id] = WakeUpCheckStateMachine.markAwaitingConfirmation(
                        latestSession,
                        now: .now
                    )
                    persistWakeUpCheckSessions()
                }
            } catch {
                if wakeUpCheckSessionsByAlarmID[alarmID]?.notificationID == nextSession.notificationID {
                    if WakeUpCheckCoordinator.shouldCancelNotificationAfterArmingFailure(
                        notificationWasScheduled: didScheduleWakeCheckNotification
                    ) {
                        wakeUpCheckNotificationService.cancel(notificationID: nextSession.notificationID)
                    }

                    wakeUpCheckSessionsByAlarmID.removeValue(forKey: alarmID)
                    persistWakeUpCheckSessions()
                }

                await applyWakeUpCheckArmingFailureResolution(
                    for: alarmID,
                    referenceDate: .now
                )
            }
        }
    }

    private func applyWakeUpCheckArmingFailureResolution(
        for alarmID: UUID,
        referenceDate: Date
    ) async {
        guard let alarmIndex = alarms.firstIndex(where: { $0.id == alarmID }) else {
            return
        }

        let resolution = WakeUpCheckCoordinator.armingFailureResolution(
            isRepeating: alarms[alarmIndex].isRepeating,
            hasActiveSessionAfterAttempt: wakeUpCheckSessionsByAlarmID[alarmID] != nil
        )

        switch resolution {
        case .keepAwaitingActiveSession:
            return

        case .restoreScheduled:
            if alarms[alarmIndex].lifecycleState != .scheduled {
                alarms[alarmIndex].lifecycleState = .scheduled
                alarms[alarmIndex].updatedAt = referenceDate
                alarms = sortAlarms(alarms)
                save()
            }

        case .completeNonRepeating:
            await completeWakeUpCheck(for: alarmID)
        }
    }

    private func completeWakeUpCheck(for alarmID: UUID) async {
        if let session = wakeUpCheckSessionsByAlarmID.removeValue(forKey: alarmID) {
            wakeUpCheckNotificationService.cancel(notificationID: session.notificationID)
            persistWakeUpCheckSessions()
        }

        guard let index = alarms.firstIndex(where: { $0.id == alarmID }) else {
            return
        }

        var alarm = alarms[index]
        alarm.snoozeCount = 0
        alarm.updatedAt = .now

        try? alarmManager.stop(id: alarmID)
        try? alarmManager.cancel(id: alarmID)
        remoteStates.removeValue(forKey: alarmID)
        lastKnownAlarmState.removeValue(forKey: alarmID)

        var pendingSnooze = AlarmPersistence.loadPendingSnoozeIDs(from: userDefaults)
        if pendingSnooze.remove(alarmID) != nil {
            AlarmPersistence.savePendingSnoozeIDs(pendingSnooze, to: userDefaults)
        }

        var pendingWakeStarts = AlarmPersistence.loadPendingWakeUpCheckStartIDs(from: userDefaults)
        if pendingWakeStarts.remove(alarmID) != nil {
            AlarmPersistence.savePendingWakeUpCheckStartIDs(pendingWakeStarts, to: userDefaults)
        }

        var pendingWakeConfirm = AlarmPersistence.loadPendingWakeUpCheckConfirmIDs(from: userDefaults)
        if pendingWakeConfirm.remove(alarmID) != nil {
            AlarmPersistence.savePendingWakeUpCheckConfirmIDs(pendingWakeConfirm, to: userDefaults)
        }

        if alarm.isRepeating, alarm.isEnabled {
            alarm.lifecycleState = .scheduled
            alarms[index] = alarm
            alarms = sortAlarms(alarms)
            save()

            do {
                let resolvedSchedule = AlarmScheduleResolver.runtimeSchedule(for: alarm)
                let config = makeConfiguration(for: alarm, schedule: resolvedSchedule)
                let remote = try await scheduleAlarmWithUpdateFallback(
                    id: alarm.id,
                    configuration: config,
                    isUpdate: true
                )
                lastKnownAlarmState[alarm.id] = remote.state
                remoteStates[alarm.id] = remote.state
            } catch {
                // Best effort. Foreground refresh can recover.
            }
            return
        }

        alarm.lifecycleState = .completed

        if alarm.deleteAfterUse {
            alarms.remove(at: index)
        } else {
            alarm.isEnabled = false
            alarm.skipNextUntilDate = nil
            alarm.nextTriggerOverrideDate = nil
            alarms[index] = alarm
        }

        alarms = sortAlarms(alarms)
        save()
    }

    private func applyRemoteAlarms(_ incoming: [Alarm]) {
        let remoteByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        let referenceDate = Date.now

        var pendingSnoozeIDs = AlarmPersistence.loadPendingSnoozeIDs(from: userDefaults)
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
                    clearTemporaryScheduleOverrideState(
                        on: &alarm,
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
                    clearTemporaryScheduleOverrideState(
                        on: &alarm,
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
                if let session = wakeUpCheckSessionsByAlarmID[alarmID],
                   session.status != .deadlineFired {
                    wakeUpCheckSessionsByAlarmID[alarmID] = WakeUpCheckStateMachine.markDeadlineFired(
                        session,
                        now: referenceDate
                    )
                    persistWakeUpCheckSessions()
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

                var pendingWakeStarts = AlarmPersistence.loadPendingWakeUpCheckStartIDs(from: userDefaults)
                if pendingWakeStarts.remove(id) != nil {
                    AlarmPersistence.savePendingWakeUpCheckStartIDs(pendingWakeStarts, to: userDefaults)
                }

                var pendingWakeConfirm = AlarmPersistence.loadPendingWakeUpCheckConfirmIDs(from: userDefaults)
                if pendingWakeConfirm.remove(id) != nil {
                    AlarmPersistence.savePendingWakeUpCheckConfirmIDs(pendingWakeConfirm, to: userDefaults)
                }

                if let session = wakeUpCheckSessionsByAlarmID.removeValue(forKey: id) {
                    wakeUpCheckNotificationService.cancel(notificationID: session.notificationID)
                }
            }
            persistWakeUpCheckSessions()
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
            AlarmPersistence.savePendingSnoozeIDs(pendingSnoozeIDs, to: userDefaults)
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
                scheduleRepeatRestore(for: alarm)
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
                    scheduleRepeatRestore(for: alarm)
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

    private func scheduleRepeatRestore(for alarm: UserAlarm) {
        guard alarm.temporaryScheduleOverride == nil else {
            return
        }

        guard !pendingRepeatRestores.contains(alarm.id) else {
            return
        }

        pendingRepeatRestores.insert(alarm.id)
        let restoredAlarm = alarm

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer { pendingRepeatRestores.remove(restoredAlarm.id) }

            do {
                let config = makeConfiguration(for: restoredAlarm, schedule: restoredAlarm.schedule)
                let remote = try await scheduleAlarmWithUpdateFallback(
                    id: restoredAlarm.id,
                    configuration: config,
                    isUpdate: true
                )
                lastKnownAlarmState[restoredAlarm.id] = remote.state
                remoteStates[restoredAlarm.id] = remote.state
            } catch {
                // Best effort; future refresh can recover.
            }
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
        let persisted = Dictionary(uniqueKeysWithValues: AlarmPersistence.loadUserAlarms(from: userDefaults).map { ($0.id, $0.snoozeCount) })

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
        alarms = sortAlarms(AlarmPersistence.loadUserAlarms(from: userDefaults))
    }

    private func save() {
        AlarmPersistence.saveUserAlarms(alarms, to: userDefaults)
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
