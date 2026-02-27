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
    @Published private(set) var activeNap: NapAlarmSession?
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
    private var wakeUpCheckSessionsByAlarmID: [UUID: WakeUpCheckSession] = [:]

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
        self.activeNap = AlarmPersistence.loadActiveNapSession(from: userDefaults)
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
            await self?.reconcilePendingWakeUpCheckConfirmations()
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
            await self?.reconcilePendingWakeUpCheckConfirmations()
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

        if var nap = activeNap, nap.useDefaultSharedSettings {
            nap.customSharedSettings = settings
            nap.updatedAt = .now
            activeNap = nap
            AlarmPersistence.saveActiveNapSession(nap, to: userDefaults)

            Task { @MainActor [weak self] in
                await self?.rescheduleActiveNap()
            }
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

        let nap = NapAlarmSession(
            id: UUID(),
            durationMinutes: draft.totalMinutes,
            targetDate: targetDate,
            pausedRemainingSeconds: nil,
            useDefaultSharedSettings: draft.useDefaultSharedSettings,
            customSharedSettings: draft.useDefaultSharedSettings ? defaultSharedSettings : draft.customSharedSettings,
            snoozeCount: 0,
            createdAt: now,
            updatedAt: now
        )

        do {
            let config = makeConfiguration(for: nap, schedule: .fixed(targetDate))
            let remoteAlarm = try await alarmManager.schedule(id: nap.id, configuration: config)
            lastKnownAlarmState[nap.id] = remoteAlarm.state
            remoteStates[nap.id] = remoteAlarm.state
            activeNap = nap
            AlarmPersistence.saveActiveNapSession(nap, to: userDefaults)
        } catch {
            throw AlarmStoreError.scheduleFailed
        }
    }

    func pauseNap() {
        guard var nap = activeNap, !nap.isPaused else {
            return
        }

        let remaining = max(1, nap.targetDate.timeIntervalSinceNow)

        do {
            try alarmManager.cancel(id: nap.id)
        } catch {
            return
        }

        nap.pausedRemainingSeconds = remaining
        nap.updatedAt = .now
        activeNap = nap
        AlarmPersistence.saveActiveNapSession(nap, to: userDefaults)
        remoteStates.removeValue(forKey: nap.id)
        lastKnownAlarmState[nap.id] = .paused
    }

    func resumeNap() async {
        guard var nap = activeNap, let pausedRemaining = nap.pausedRemainingSeconds else {
            return
        }

        let nextTarget = Date.now.addingTimeInterval(max(1, pausedRemaining))

        do {
            let config = makeConfiguration(for: nap, schedule: .fixed(nextTarget))
            let remoteAlarm = try await alarmManager.schedule(id: nap.id, configuration: config)
            nap.targetDate = nextTarget
            nap.pausedRemainingSeconds = nil
            nap.updatedAt = .now
            activeNap = nap
            AlarmPersistence.saveActiveNapSession(nap, to: userDefaults)
            remoteStates[nap.id] = remoteAlarm.state
            lastKnownAlarmState[nap.id] = remoteAlarm.state
        } catch {
            // Keep paused state when resume fails.
        }
    }

    func deleteNap() {
        guard let nap = activeNap else {
            return
        }

        try? alarmManager.stop(id: nap.id)
        try? alarmManager.cancel(id: nap.id)

        var pending = AlarmPersistence.loadPendingSnoozeIDs(from: userDefaults)
        if pending.remove(nap.id) != nil {
            AlarmPersistence.savePendingSnoozeIDs(pending, to: userDefaults)
        }

        activeNap = nil
        AlarmPersistence.saveActiveNapSession(nil, to: userDefaults)
        remoteStates.removeValue(forKey: nap.id)
        lastKnownAlarmState.removeValue(forKey: nap.id)
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

        current.isEnabled = true
        current.skipNextUntilDate = nil
        current.nextTriggerOverrideDate = nextOverrideDate
        current.temporaryScheduleOverride = activation.overrideState
        current.manualScheduleQueue = buildManualQueueEntries(
            triggerDates: activation.manualTriggerDates,
            restoreAnchorDate: activation.overrideState.restoreAnchorDate,
            configReferenceID: current.scheduleConfigReferenceID,
            overrideDate: activation.overrideState.overrideDate
        )
        current.snoozeCount = 0
        current.updatedAt = now

        alarms[index] = current
        alarms = sortAlarms(alarms)
        save()

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
            updatedAlarm.isEnabled = true
            updatedAlarm.skipNextUntilDate = nil
            updatedAlarm.nextTriggerOverrideDate = nil
            updatedAlarm.temporaryScheduleOverride = nil
            updatedAlarm.manualScheduleQueue.removeAll()
            updatedAlarm.updatedAt = now
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
            // this assignment replaces any previous temporary override mode.
            updatedAlarm.isEnabled = false
            updatedAlarm.skipNextUntilDate = activation.overrideState.skippedCanonicalDate
            updatedAlarm.nextTriggerOverrideDate = nil
            updatedAlarm.temporaryScheduleOverride = activation.overrideState
            updatedAlarm.manualScheduleQueue = buildManualQueueEntries(
                triggerDates: activation.manualTriggerDates,
                restoreAnchorDate: activation.overrideState.restoreAnchorDate,
                configReferenceID: updatedAlarm.scheduleConfigReferenceID,
                overrideDate: activation.overrideState.overrideDate
            )
            updatedAlarm.updatedAt = now
        } else {
            // Full disable clears all temporary scheduling state.
            updatedAlarm.isEnabled = false
            updatedAlarm.skipNextUntilDate = nil
            updatedAlarm.nextTriggerOverrideDate = nil
            updatedAlarm.temporaryScheduleOverride = nil
            updatedAlarm.manualScheduleQueue.removeAll()
            updatedAlarm.updatedAt = now

            if let session = wakeUpCheckSessionsByAlarmID.removeValue(forKey: updatedAlarm.id) {
                wakeUpCheckNotificationService.cancel(notificationID: session.notificationID)
                persistWakeUpCheckSessions()
            }

            var pending = AlarmPersistence.loadPendingSnoozeIDs(from: userDefaults)
            if pending.remove(updatedAlarm.id) != nil {
                AlarmPersistence.savePendingSnoozeIDs(pending, to: userDefaults)
            }
        }

        updatedAlarm.lifecycleState = .scheduled

        alarms[index] = updatedAlarm
        alarms = sortAlarms(alarms)
        save()

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

        // Keep only one active trial alarm at a time.
        var existingTrials = AlarmPersistence.loadShadowTrials(from: userDefaults)
        if !existingTrials.isEmpty {
            for trial in existingTrials {
                try? alarmManager.stop(id: trial.id)
                try? alarmManager.cancel(id: trial.id)
                lastKnownAlarmState.removeValue(forKey: trial.id)
                remoteStates.removeValue(forKey: trial.id)
            }

            var pending = AlarmPersistence.loadPendingSnoozeIDs(from: userDefaults)
            for trial in existingTrials {
                pending.remove(trial.id)
            }
            AlarmPersistence.savePendingSnoozeIDs(pending, to: userDefaults)

            existingTrials.removeAll()
            AlarmPersistence.saveShadowTrials(existingTrials, to: userDefaults)
        }

        let shadowID = UUID()

        var trialDraft = draft
        let trialSharedSettings = draft.resolvedSharedSettings(defaults: defaultSharedSettings)
        trialDraft.useDefaultSharedSettings = false
        trialDraft.customSharedSettings = trialSharedSettings

        let baseAlarm = trialDraft.toUserAlarm(
            id: shadowID,
            existingCreatedAt: nil,
            defaultSharedSettings: defaultSharedSettings,
            existingSnoozeCount: 0
        )
        let trialDate = Date.now.addingTimeInterval(seconds)

        let config = makeConfiguration(for: baseAlarm, schedule: .fixed(trialDate), isShadowTrial: true)
        _ = try await alarmManager.schedule(id: shadowID, configuration: config)

        var trials = AlarmPersistence.loadShadowTrials(from: userDefaults)
        trials.append(ShadowTrialAlarm(
            id: shadowID,
            name: baseAlarm.name,
            snoozeEnabled: trialSharedSettings.snoozeEnabled,
            snoozeDurationMinutes: trialSharedSettings.snoozeDurationMinutes,
            maxSnoozes: trialSharedSettings.maxSnoozes,
            snoozeCount: 0,
            wakeUpCheckEnabled: trialSharedSettings.wakeUpCheckEnabled,
            lifecycleState: .scheduled,
            createdAt: .now,
            updatedAt: .now
        ))
        AlarmPersistence.saveShadowTrials(trials, to: userDefaults)
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
            existingAlarm.hour != nextAlarm.hour ||
                existingAlarm.minute != nextAlarm.minute ||
                Set(existingAlarm.repeatDays) != Set(nextAlarm.repeatDays)
        } else {
            false
        }

        let shouldClearOverride = clearNextOverride || canonicalScheduleChanged || !nextAlarm.isRepeating

        if shouldClearOverride {
            if existingAlarm?.temporaryScheduleOverride?.kind == .disableNext {
                // Schedule edits must restore canonical recurring intent.
                nextAlarm.isEnabled = true
            }

            nextAlarm.temporaryScheduleOverride = nil
            nextAlarm.manualScheduleQueue.removeAll()
            nextAlarm.nextTriggerOverrideDate = nil
            nextAlarm.skipNextUntilDate = nil
        }

        nextAlarm.updatedAt = now

        let wakeCheckEnabled = nextAlarm.resolvedSharedSettings(defaults: defaultSharedSettings).wakeUpCheckEnabled
        if !wakeCheckEnabled,
           let session = wakeUpCheckSessionsByAlarmID.removeValue(forKey: id) {
            wakeUpCheckNotificationService.cancel(notificationID: session.notificationID)
            persistWakeUpCheckSessions()
        }

        if let existingIndex = alarms.firstIndex(where: { $0.id == id }) {
            alarms[existingIndex] = nextAlarm
        } else {
            alarms.append(nextAlarm)
        }

        alarms = sortAlarms(alarms)
        save()

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
        guard let nap = activeNap, !nap.isPaused else {
            return
        }

        do {
            let config = makeConfiguration(for: nap, schedule: .fixed(nap.targetDate))
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

    func reconcileSchedule(target: AlarmScheduleReconcileTarget, referenceDate: Date) async {
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
        let alarmIDs = alarms.map(\.id)
        for alarmID in alarmIDs {
            await reconcileSchedulingForAlarm(alarmID, referenceDate: referenceDate)
        }
    }

    /// Applies scheduling state for a single alarm without consulting wake-check
    /// or snooze configuration gates.
    private func reconcileSchedulingForAlarm(_ alarmID: UUID, referenceDate: Date = .now) async {
        guard let index = alarms.firstIndex(where: { $0.id == alarmID }) else {
            return
        }

        var alarm = alarms[index]
        var changed = false

        if let overrideState = alarm.temporaryScheduleOverride,
           alarm.isRepeating {
            let desiredDates = AlarmSchedulePlanner.desiredManualTriggerDates(
                canonicalSchedule: alarm.canonicalScheduleSpec,
                overrideState: overrideState,
                now: referenceDate,
                manualQueueDepth: manualOverrideQueueDepth
            )

            if desiredDates.isEmpty {
                if overrideState.kind == .disableNext {
                    alarm.isEnabled = true
                }
                alarm.temporaryScheduleOverride = nil
                alarm.manualScheduleQueue.removeAll()
                alarm.skipNextUntilDate = nil
                alarm.nextTriggerOverrideDate = nil
                alarm.updatedAt = referenceDate
                changed = true
            } else {
                var existingByDate: [Date: AlarmManualScheduleEntry] = [:]
                for entry in alarm.manualScheduleQueue where existingByDate[entry.triggerDate] == nil {
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
                        configReferenceID: alarm.scheduleConfigReferenceID,
                        role: (overrideState.overrideDate != nil && date == overrideState.overrideDate) ? .overrideTrigger : .canonicalBridge
                    )
                }

                let staleManualIDs = Set(alarm.manualScheduleQueue.map(\.id))
                    .subtracting(Set(rebuiltQueue.map(\.id)))

                if !staleManualIDs.isEmpty {
                    await cancelRuntimeAlarms(ids: staleManualIDs)
                }

                if rebuiltQueue != alarm.manualScheduleQueue {
                    alarm.manualScheduleQueue = rebuiltQueue
                    alarm.updatedAt = referenceDate
                    changed = true
                }

                // While override is active, recurring schedule must be removed.
                try? alarmManager.stop(id: alarm.id)
                try? alarmManager.cancel(id: alarm.id)
                lastKnownAlarmState.removeValue(forKey: alarm.id)

                for manual in alarm.manualScheduleQueue {
                    guard manual.triggerDate > referenceDate.addingTimeInterval(-1) else {
                        continue
                    }

                    do {
                        let config = makeConfiguration(
                            for: alarm,
                            schedule: .fixed(manual.triggerDate),
                            isShadowTrial: false,
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

                remoteStates[alarm.id] = alarm.manualScheduleQueue.isEmpty ? nil : .scheduled
            }
        }

        if alarm.temporaryScheduleOverride == nil {
            if !alarm.manualScheduleQueue.isEmpty {
                let staleManualIDs = Set(alarm.manualScheduleQueue.map(\.id))
                await cancelRuntimeAlarms(ids: staleManualIDs)
                alarm.manualScheduleQueue.removeAll()
                changed = true
            }

            if alarm.isEnabled {
                do {
                    let config = makeConfiguration(for: alarm, schedule: alarm.schedule, isShadowTrial: false)
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

        if changed {
            alarms[index] = alarm
            alarms = sortAlarms(alarms)
            save()
        }
    }

    private func makeConfiguration(
        for alarm: UserAlarm,
        schedule: Alarm.Schedule,
        isShadowTrial: Bool,
        forceDisableSnooze: Bool = false,
        runtimeAlarmID: UUID? = nil,
        configReferenceID: UUID? = nil
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let sharedSettings = alarm.resolvedSharedSettings(defaults: defaultSharedSettings)

        return makeConfiguration(
            runtimeAlarmID: runtimeAlarmID ?? alarm.id,
            configReferenceID: configReferenceID ?? alarm.scheduleConfigReferenceID,
            title: resolvedAlarmTitle(from: alarm.name),
            schedule: schedule,
            sharedSettings: sharedSettings,
            snoozeCount: alarm.snoozeCount,
            isShadowTrial: isShadowTrial,
            forceDisableSnooze: forceDisableSnooze
        )
    }

    private func makeConfiguration(
        for nap: NapAlarmSession,
        schedule: Alarm.Schedule
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let sharedSettings = nap.resolvedSharedSettings(defaults: defaultSharedSettings)

        return makeConfiguration(
            runtimeAlarmID: nap.id,
            configReferenceID: nap.id,
            title: String(localized: "nap_default_alarm_label"),
            schedule: schedule,
            sharedSettings: sharedSettings,
            snoozeCount: nap.snoozeCount,
            isShadowTrial: false,
            forceDisableSnooze: false
        )
    }

    private func makeConfiguration(
        runtimeAlarmID: UUID,
        configReferenceID: UUID,
        title: String,
        schedule: Alarm.Schedule,
        sharedSettings: SharedAlarmSettings,
        snoozeCount: Int,
        isShadowTrial: Bool,
        forceDisableSnooze: Bool
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let showSnoozeButton = !forceDisableSnooze && sharedSettings.canSnoozeAgain(currentCount: snoozeCount)

        let alertPresentation = AlarmPresentation.Alert(
            title: localizedResource(from: title),
            stopButton: .stopButton,
            secondaryButton: showSnoozeButton ? .snoozeButton : nil,
            secondaryButtonBehavior: showSnoozeButton ? .custom : nil
        )

        let presentation = AlarmPresentation(alert: alertPresentation)

        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: OpenAlarmMetadata(source: configReferenceID.uuidString, isShadowTrial: isShadowTrial),
            tintColor: OAColor.actionCyan
        )

        let secondaryIntent: (any LiveActivityIntent)? = if showSnoozeButton {
            SnoozeIntent(alarmID: runtimeAlarmID.uuidString)
        } else {
            nil
        }

        let countdownDuration: Alarm.CountdownDuration? = if showSnoozeButton {
            .init(preAlert: nil, postAlert: snoozeInterval(for: sharedSettings.snoozeDurationMinutes))
        } else {
            nil
        }

        return .init(
            countdownDuration: countdownDuration,
            schedule: schedule,
            attributes: attributes,
            stopIntent: StopIntent(alarmID: runtimeAlarmID.uuidString),
            secondaryIntent: secondaryIntent,
            sound: .default
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

                await reconcilePendingWakeUpCheckConfirmations()
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

        var pendingConfirm = AlarmPersistence.loadPendingWakeUpCheckConfirmIDs(from: userDefaults)
        if !pendingConfirm.isEmpty {
            pendingConfirm.removeAll()
            AlarmPersistence.savePendingWakeUpCheckConfirmIDs(pendingConfirm, to: userDefaults)
        }
    }

    private func startWakeUpCheckCycle(for alarm: inout UserAlarm, changed: inout Bool) -> Bool {
        guard notificationPermissionStatus == .authorized else {
            if let session = wakeUpCheckSessionsByAlarmID.removeValue(forKey: alarm.id) {
                wakeUpCheckNotificationService.cancel(notificationID: session.notificationID)
                persistWakeUpCheckSessions()
            }

            return false
        }

        let resolvedSettings = alarm.resolvedSharedSettings(defaults: defaultSharedSettings)
        let checkAt = Date.now.addingTimeInterval(
            WakeUpCheckTimingPolicy.checkDelayInterval(for: resolvedSettings.wakeUpCheckDelayMinutes)
        )
        let deadlineAt = checkAt.addingTimeInterval(
            WakeUpCheckTimingPolicy.responseTimeoutInterval(for: resolvedSettings.wakeUpCheckResponseTimeoutMinutes)
        )

        let previousCycle = wakeUpCheckSessionsByAlarmID[alarm.id]?.cycle ?? 0
        let session = WakeUpCheckSession(
            alarmID: alarm.id,
            cycle: previousCycle + 1,
            checkAt: checkAt,
            deadlineAt: deadlineAt,
            notificationID: WakeUpCheckNotificationConstants.notificationID(alarmID: alarm.id, cycle: previousCycle + 1),
            isAwaitingConfirmation: true,
            createdAt: .now,
            updatedAt: .now
        )

        if let previous = wakeUpCheckSessionsByAlarmID[alarm.id] {
            wakeUpCheckNotificationService.cancel(notificationID: previous.notificationID)
        }

        wakeUpCheckSessionsByAlarmID[alarm.id] = session
        persistWakeUpCheckSessions()

        if alarm.lifecycleState != .awaitingWakeCheck {
            alarm.lifecycleState = .awaitingWakeCheck
            changed = true
        }

        let alarmID = alarm.id

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            guard let latestAlarm = alarms.first(where: { $0.id == alarmID }) else {
                if wakeUpCheckSessionsByAlarmID[alarmID]?.notificationID == session.notificationID {
                    wakeUpCheckSessionsByAlarmID.removeValue(forKey: alarmID)
                    persistWakeUpCheckSessions()
                }
                return
            }

            do {
                try await wakeUpCheckNotificationService.scheduleWakeCheckNotification(for: session)

                let config = makeConfiguration(
                    for: latestAlarm,
                    schedule: .fixed(deadlineAt),
                    isShadowTrial: false,
                    forceDisableSnooze: true
                )
                let remoteAlarm = try await scheduleAlarmWithUpdateFallback(
                    id: latestAlarm.id,
                    configuration: config,
                    isUpdate: true
                )

                lastKnownAlarmState[latestAlarm.id] = remoteAlarm.state
                remoteStates[latestAlarm.id] = remoteAlarm.state
            } catch {
                if wakeUpCheckSessionsByAlarmID[latestAlarm.id]?.notificationID == session.notificationID {
                    wakeUpCheckSessionsByAlarmID.removeValue(forKey: latestAlarm.id)
                    persistWakeUpCheckSessions()
                }
            }
        }

        return true
    }

    private func reconcilePendingWakeUpCheckConfirmations() async {
        var pendingConfirmIDs = AlarmPersistence.loadPendingWakeUpCheckConfirmIDs(from: userDefaults)
        guard !pendingConfirmIDs.isEmpty else {
            return
        }

        for alarmID in pendingConfirmIDs {
            await completeWakeUpCheck(for: alarmID)
        }

        pendingConfirmIDs.removeAll()
        AlarmPersistence.savePendingWakeUpCheckConfirmIDs(pendingConfirmIDs, to: userDefaults)
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

        if alarm.isRepeating, alarm.isEnabled {
            alarm.lifecycleState = .scheduled
            alarms[index] = alarm
            alarms = sortAlarms(alarms)
            save()

            do {
                let config = makeConfiguration(for: alarm, schedule: alarm.schedule, isShadowTrial: false)
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

        handleShadowTrials(remoteByID: remoteByID, pendingSnoozeIDs: &pendingSnoozeIDs)

        var idsToAutoDelete: Set<UUID> = []

        for index in updated.indices {
            var alarm = updated[index]

            // Temporary override mode is tracked via explicit manual one-shots.
            // Their callback transitions drive deterministic recurring restore.
            if let overrideState = alarm.temporaryScheduleOverride {
                guard !alarm.manualScheduleQueue.isEmpty else {
                    alarm.temporaryScheduleOverride = nil
                    alarm.nextTriggerOverrideDate = nil
                    alarm.skipNextUntilDate = nil
                    alarm.isEnabled = true
                    alarm.lifecycleState = .scheduled
                    alarm.updatedAt = referenceDate
                    updated[index] = alarm
                    changed = true
                    continue
                }

                var shouldRestoreRecurring = false
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
                        if AlarmSchedulePlanner.shouldRestoreRecurringSchedule(
                            afterManualAlarmFiredAt: manual.triggerDate,
                            overrideState: overrideState
                        ) {
                            shouldRestoreRecurring = true
                        }
                    }
                }

                // Base recurring runtime alarm must stay absent while override is active.
                try? alarmManager.stop(id: alarm.id)
                try? alarmManager.cancel(id: alarm.id)
                lastKnownAlarmState.removeValue(forKey: alarm.id)

                if shouldRestoreRecurring {
                    let staleManualIDs = Set(alarm.manualScheduleQueue.map(\.id))
                    for id in staleManualIDs {
                        try? alarmManager.stop(id: id)
                        try? alarmManager.cancel(id: id)
                        lastKnownAlarmState.removeValue(forKey: id)
                        pendingSnoozeIDs.remove(id)
                    }

                    alarm.temporaryScheduleOverride = nil
                    alarm.manualScheduleQueue.removeAll()
                    alarm.nextTriggerOverrideDate = nil
                    alarm.skipNextUntilDate = nil
                    alarm.isEnabled = true
                    alarm.lifecycleState = .scheduled
                    alarm.updatedAt = referenceDate
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

                if let session = wakeUpCheckSessionsByAlarmID.removeValue(forKey: id) {
                    wakeUpCheckNotificationService.cancel(notificationID: session.notificationID)
                }
            }
            persistWakeUpCheckSessions()
            updated.removeAll { idsToAutoDelete.contains($0.id) }
            changed = true
        }

        _ = handleActiveNap(remoteByID: remoteByID, pendingSnoozeIDs: &pendingSnoozeIDs)

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

            if wakeCheckEnabled,
               startWakeUpCheckCycle(for: &alarm, changed: &changed) {
                return
            }

            if alarm.lifecycleState != .scheduled {
                alarm.lifecycleState = .scheduled
                changed = true
            }
            return
        }

        if wakeCheckEnabled,
           startWakeUpCheckCycle(for: &alarm, changed: &changed) {
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
                let config = makeConfiguration(for: restoredAlarm, schedule: restoredAlarm.schedule, isShadowTrial: false)
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
    private func handleActiveNap(remoteByID: [UUID: Alarm], pendingSnoozeIDs: inout Set<UUID>) -> Bool {
        guard var nap = activeNap else {
            return false
        }

        let previousState = lastKnownAlarmState[nap.id]
        let currentState = remoteByID[nap.id]?.state

        if let currentState {
            lastKnownAlarmState[nap.id] = currentState
            remoteStates[nap.id] = currentState
        } else {
            remoteStates.removeValue(forKey: nap.id)
            if nap.isPaused {
                lastKnownAlarmState[nap.id] = .paused
            } else {
                lastKnownAlarmState.removeValue(forKey: nap.id)
            }
        }

        if previousState == .alerting, currentState != .alerting {
            clearActiveNap(pendingSnoozeIDs: &pendingSnoozeIDs)
            return true
        }

        if currentState == .paused {
            if nap.pausedRemainingSeconds == nil {
                nap.pausedRemainingSeconds = max(1, nap.targetDate.timeIntervalSinceNow)
                nap.updatedAt = .now
                persistActiveNap(nap)
                return true
            }
            return false
        }

        if nap.isPaused, (currentState == .countdown || currentState == .scheduled) {
            nap.pausedRemainingSeconds = nil
            nap.targetDate = max(Date.now, nap.targetDate)
            nap.updatedAt = .now
            persistActiveNap(nap)
            return true
        }

        if !nap.isPaused, currentState == nil, nap.targetDate <= .now {
            clearActiveNap(pendingSnoozeIDs: &pendingSnoozeIDs)
            return true
        }

        return false
    }

    private func persistActiveNap(_ nap: NapAlarmSession?) {
        activeNap = nap
        AlarmPersistence.saveActiveNapSession(nap, to: userDefaults)
    }

    private func clearActiveNap(pendingSnoozeIDs: inout Set<UUID>) {
        guard let nap = activeNap else {
            return
        }

        pendingSnoozeIDs.remove(nap.id)
        remoteStates.removeValue(forKey: nap.id)
        lastKnownAlarmState.removeValue(forKey: nap.id)
        persistActiveNap(nil)
    }

    private func handleShadowTrials(remoteByID: [UUID: Alarm], pendingSnoozeIDs: inout Set<UUID>) {
        var trials = AlarmPersistence.loadShadowTrials(from: userDefaults)
        var changed = false

        for index in trials.indices.reversed() {
            let trialID = trials[index].id
            let previousState = lastKnownAlarmState[trialID]
            let currentState = remoteByID[trialID]?.state

            if let currentState {
                lastKnownAlarmState[trialID] = currentState
            } else {
                lastKnownAlarmState.removeValue(forKey: trialID)
            }

            if isSnoozeTransitionState(currentState) {
                pendingSnoozeIDs.remove(trialID)
            }

            if previousState == .alerting, currentState != .alerting {
                if pendingSnoozeIDs.contains(trialID) {
                    if trials[index].lifecycleState != .scheduled {
                        trials[index].lifecycleState = .scheduled
                        trials[index].updatedAt = .now
                        changed = true
                    }
                    continue
                }

                if trials[index].snoozeEnabled,
                   trials[index].snoozeCount > 0,
                   isSnoozeTransitionState(currentState) {
                    if trials[index].lifecycleState != .scheduled {
                        trials[index].lifecycleState = .scheduled
                        trials[index].updatedAt = .now
                        changed = true
                    }
                    continue
                }

                if trials[index].wakeUpCheckEnabled {
                    if trials[index].lifecycleState != .awaitingWakeCheck {
                        trials[index].lifecycleState = .awaitingWakeCheck
                        trials[index].updatedAt = .now
                        changed = true
                    }
                    continue
                }

                try? alarmManager.stop(id: trialID)
                try? alarmManager.cancel(id: trialID)
                trials.remove(at: index)
                pendingSnoozeIDs.remove(trialID)
                changed = true
                continue
            }

            if let currentState {
                switch currentState {
                case .alerting:
                    if trials[index].lifecycleState != .alerting {
                        trials[index].lifecycleState = .alerting
                        trials[index].updatedAt = .now
                        changed = true
                    }
                case .scheduled, .countdown, .paused:
                    if trials[index].lifecycleState != .scheduled {
                        trials[index].lifecycleState = .scheduled
                        trials[index].updatedAt = .now
                        changed = true
                    }
                @unknown default:
                    break
                }
            }

            if currentState == nil, trials[index].lifecycleState != .awaitingWakeCheck {
                trials.remove(at: index)
                pendingSnoozeIDs.remove(trialID)
                changed = true
            }
        }

        if changed {
            AlarmPersistence.saveShadowTrials(trials, to: userDefaults)
        }
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

    private func snoozeInterval(for minutes: Int) -> TimeInterval {
        if minutes == 0 {
            return 5
        }
        return TimeInterval(minutes * 60)
    }

    private func resolvedAlarmTitle(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return NSLocalizedString("alarm_editor_default_label", comment: "")
        }
        return trimmed
    }

    private func localizedResource(from text: String) -> LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(text))
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
