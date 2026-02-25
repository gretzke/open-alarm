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
    @Published private(set) var activeNap: NapAlarmSession?
    @Published private(set) var permissionStatus: AlarmPermissionStatus
    @Published private(set) var remoteStates: [UUID: Alarm.State] = [:]

    private let alarmManager: AlarmManager
    private let permissionService: AlarmPermissionService
    private let userDefaults: UserDefaults

    private var alarmUpdatesTask: Task<Void, Never>?
    private var lastKnownAlarmState: [UUID: Alarm.State] = [:]
    private var pendingRepeatRestores: Set<UUID> = []

    init(
        alarmManager: AlarmManager = .shared,
        permissionService: AlarmPermissionService? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.alarmManager = alarmManager
        self.permissionService = permissionService ?? AlarmPermissionService(manager: alarmManager)
        self.userDefaults = userDefaults
        self.defaultSharedSettings = AlarmPersistence.loadDefaultSharedSettings(from: userDefaults)
        self.defaultNapDurationMinutes = AlarmPersistence.loadDefaultNapDurationMinutes(from: userDefaults)
        self.testingModeEnabled = AlarmPersistence.loadTestingModeEnabled(from: userDefaults)
        self.activeNap = AlarmPersistence.loadActiveNapSession(from: userDefaults)
        self.permissionStatus = self.permissionService.currentStatus()

        load()
        observeAlarmUpdates()
        refreshFromSystem()
    }

    deinit {
        alarmUpdatesTask?.cancel()
    }

    func handleAppOpened() {
        refreshFromSystem()
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

        var current = alarms[index]
        let timeComponents = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: draft.time)
        let overrideHour = timeComponents.hour ?? current.hour
        let overrideMinute = timeComponents.minute ?? current.minute

        guard let nextOverrideDate = nextOccurrenceDate(
            in: current.sortedRepeatDays,
            hour: overrideHour,
            minute: overrideMinute,
            after: .now
        ) else {
            throw AlarmStoreError.scheduleFailed
        }

        current.nextTriggerOverrideDate = nextOverrideDate
        current.isEnabled = true
        current.skipNextUntilDate = nil
        current.snoozeCount = 0
        current.updatedAt = .now

        do {
            let config = makeConfiguration(for: current, schedule: current.schedule, isShadowTrial: false)
            let remoteAlarm = try await scheduleAlarmWithUpdateFallback(
                id: current.id,
                configuration: config,
                isUpdate: true
            )
            current.lifecycleState = remoteAlarm.state == .alerting ? .alerting : .scheduled
            lastKnownAlarmState[current.id] = remoteAlarm.state
            remoteStates[current.id] = remoteAlarm.state
        } catch {
            throw AlarmStoreError.scheduleFailed
        }

        alarms[index] = current
        alarms = sortAlarms(alarms)
        save()
    }

    func deleteAlarm(_ alarm: UserAlarm) {
        try? alarmManager.cancel(id: alarm.id)
        alarms.removeAll { $0.id == alarm.id }
        remoteStates.removeValue(forKey: alarm.id)
        lastKnownAlarmState.removeValue(forKey: alarm.id)

        var pending = AlarmPersistence.loadPendingSnoozeIDs(from: userDefaults)
        if pending.remove(alarm.id) != nil {
            AlarmPersistence.savePendingSnoozeIDs(pending, to: userDefaults)
        }

        save()
    }

    func scheduleTryOut(sharedSettings: SharedAlarmSettings, after seconds: TimeInterval) async throws {
        let draft = AlarmDraft(
            name: "",
            time: .now,
            repeatDays: [],
            deleteAfterUse: true,
            wakeUpCheckEnabled: false,
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
            wakeUpCheckEnabled: baseAlarm.wakeUpCheckEnabled,
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

    private func upsertAlarm(existingAlarm: UserAlarm?, draft: AlarmDraft, clearNextOverride: Bool = false) async throws {
        try await ensureAuthorizedForScheduling()

        let id = existingAlarm?.id ?? UUID()
        var nextAlarm = draft.toUserAlarm(
            id: id,
            existingCreatedAt: existingAlarm?.createdAt,
            defaultSharedSettings: defaultSharedSettings,
            existingSnoozeCount: existingAlarm?.snoozeCount
        )

        if nextAlarm.isEnabled || nextAlarm.isSkippingNext {
            do {
                let config = makeConfiguration(for: nextAlarm, schedule: nextAlarm.schedule, isShadowTrial: false)
                let remoteAlarm = try await scheduleAlarmWithUpdateFallback(
                    id: id,
                    configuration: config,
                    isUpdate: existingAlarm != nil
                )
                nextAlarm.lifecycleState = remoteAlarm.state == .alerting ? .alerting : .scheduled
                nextAlarm.snoozeCount = 0
                lastKnownAlarmState[id] = remoteAlarm.state
                remoteStates[id] = remoteAlarm.state
            } catch {
                throw AlarmStoreError.scheduleFailed
            }
        } else {
            try? alarmManager.stop(id: id)
            try? alarmManager.cancel(id: id)
            nextAlarm.lifecycleState = .scheduled
            nextAlarm.snoozeCount = 0
            lastKnownAlarmState.removeValue(forKey: id)
            remoteStates.removeValue(forKey: id)
        }

        if let existingIndex = alarms.firstIndex(where: { $0.id == id }) {
            alarms[existingIndex] = nextAlarm
        } else {
            alarms.append(nextAlarm)
        }

        alarms = sortAlarms(alarms)
        save()
    }

    private func ensureAuthorizedForScheduling() async throws {
        let status = await requestPermissionIfNeeded()
        guard status == .authorized else {
            throw AlarmStoreError.permissionDenied
        }
    }

    private func rescheduleAlarmsUsingDefaultSharedSettings() async {
        for alarm in alarms where alarm.useDefaultSharedSettings {
            guard alarm.isEnabled || alarm.isSkippingNext else {
                continue
            }

            do {
                let config = makeConfiguration(for: alarm, schedule: alarm.schedule, isShadowTrial: false)
                let remote = try await alarmManager.schedule(id: alarm.id, configuration: config)
                lastKnownAlarmState[alarm.id] = remote.state
                remoteStates[alarm.id] = remote.state
            } catch {
                // Best effort only; next refresh can reconcile state.
            }
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

    private func makeConfiguration(
        for alarm: UserAlarm,
        schedule: Alarm.Schedule,
        isShadowTrial: Bool
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let sharedSettings = alarm.resolvedSharedSettings(defaults: defaultSharedSettings)

        return makeConfiguration(
            alarmID: alarm.id,
            title: resolvedAlarmTitle(from: alarm.name),
            schedule: schedule,
            sharedSettings: sharedSettings,
            snoozeCount: alarm.snoozeCount,
            isShadowTrial: isShadowTrial
        )
    }

    private func makeConfiguration(
        for nap: NapAlarmSession,
        schedule: Alarm.Schedule
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let sharedSettings = nap.resolvedSharedSettings(defaults: defaultSharedSettings)

        return makeConfiguration(
            alarmID: nap.id,
            title: String(localized: "nap_default_alarm_label"),
            schedule: schedule,
            sharedSettings: sharedSettings,
            snoozeCount: nap.snoozeCount,
            isShadowTrial: false
        )
    }

    private func makeConfiguration(
        alarmID: UUID,
        title: String,
        schedule: Alarm.Schedule,
        sharedSettings: SharedAlarmSettings,
        snoozeCount: Int,
        isShadowTrial: Bool
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let showSnoozeButton = sharedSettings.canSnoozeAgain(currentCount: snoozeCount)

        let alertPresentation = AlarmPresentation.Alert(
            title: localizedResource(from: title),
            stopButton: .stopButton,
            secondaryButton: showSnoozeButton ? .snoozeButton : nil,
            secondaryButtonBehavior: showSnoozeButton ? .custom : nil
        )

        let presentation = AlarmPresentation(alert: alertPresentation)

        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: OpenAlarmMetadata(source: alarmID.uuidString, isShadowTrial: isShadowTrial),
            tintColor: OAColor.actionCyan
        )

        let secondaryIntent: (any LiveActivityIntent)? = if showSnoozeButton {
            SnoozeIntent(alarmID: alarmID.uuidString)
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
            stopIntent: nil,
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
                applyRemoteAlarms(incoming)
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
    }

    private func applyRemoteAlarms(_ incoming: [Alarm]) {
        let remoteByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })

        var pendingSnoozeIDs = AlarmPersistence.loadPendingSnoozeIDs(from: userDefaults)
        let originalPending = pendingSnoozeIDs

        var updated = alarms
        var changed = mergeSnoozeCountsFromPersistence(into: &updated)

        handleShadowTrials(remoteByID: remoteByID, pendingSnoozeIDs: &pendingSnoozeIDs)

        remoteStates = Dictionary(
            uniqueKeysWithValues: updated.compactMap { alarm in
                guard let state = remoteByID[alarm.id]?.state else {
                    return nil
                }
                return (alarm.id, state)
            }
        )

        var idsToAutoDelete: Set<UUID> = []

        for index in updated.indices {
            let alarmID = updated[index].id
            let previousState = lastKnownAlarmState[alarmID]
            let currentState = remoteByID[alarmID]?.state

            if let currentState {
                lastKnownAlarmState[alarmID] = currentState
            } else {
                lastKnownAlarmState.removeValue(forKey: alarmID)
            }

            if isSnoozeTransitionState(currentState) {
                pendingSnoozeIDs.remove(alarmID)
            }

            if updated[index].isRepeating,
               let overrideDate = updated[index].nextTriggerOverrideDate,
               currentState == nil,
               overrideDate <= .now {
                updated[index].nextTriggerOverrideDate = nil
                updated[index].updatedAt = .now
                scheduleRepeatRestore(for: updated[index])
                changed = true
            }

            if previousState == .alerting, currentState != .alerting {
                applyPostAlertTransition(
                    alarm: &updated[index],
                    currentState: currentState,
                    pendingSnoozeIDs: &pendingSnoozeIDs,
                    idsToAutoDelete: &idsToAutoDelete,
                    changed: &changed
                )
                continue
            }

            guard let currentState else {
                continue
            }

            switch currentState {
            case .alerting:
                if updated[index].lifecycleState != .alerting {
                    updated[index].lifecycleState = .alerting
                    changed = true
                }
            case .scheduled, .countdown, .paused:
                if updated[index].lifecycleState != .scheduled {
                    updated[index].lifecycleState = .scheduled
                    changed = true
                }
            @unknown default:
                break
            }
        }

        if !idsToAutoDelete.isEmpty {
            for id in idsToAutoDelete {
                try? alarmManager.cancel(id: id)
                remoteStates.removeValue(forKey: id)
                lastKnownAlarmState.removeValue(forKey: id)
                pendingSnoozeIDs.remove(id)
            }
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
            if !alarm.isEnabled,
               let skipUntil = alarm.skipNextUntilDate,
               skipUntil <= .now {
                alarm.isEnabled = true
                alarm.skipNextUntilDate = nil
                alarm.updatedAt = .now
                changed = true
            }

            if let overrideDate = alarm.nextTriggerOverrideDate {
                let overrideConsumed =
                    (previousState == .alerting && currentState != .alerting) ||
                    (currentState == nil && overrideDate <= .now)

                if overrideConsumed {
                    alarm.nextTriggerOverrideDate = nil
                    alarm.updatedAt = .now
                    changed = true
                    if alarm.isEnabled || alarm.isSkippingNext {
                        scheduleRepeatRestore(for: alarm)
                    }
                }
            } else if hadSnoozes, alarm.isEnabled {
                scheduleRepeatRestore(for: alarm)
            }

            if alarm.lifecycleState != .scheduled {
                alarm.lifecycleState = .scheduled
                changed = true
            }
            return
        }

        if alarm.wakeUpCheckEnabled {
            if alarm.lifecycleState != .awaitingWakeCheck {
                alarm.lifecycleState = .awaitingWakeCheck
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
        }
    }

    private func scheduleRepeatRestore(for alarm: UserAlarm) {
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

        if nap.isPaused, currentState == .countdown || currentState == .scheduled {
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
