import AlarmKit
import Foundation

// MARK: - Alarm create / update / delete / toggle / try-out

extension AlarmStore {

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

        let (overrideHour, overrideMinute) = extractOverrideTimeComponents(from: draft, fallback: current)

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
        await AlarmScheduleReconcileEntrypoint.reconcileSchedule(alarmID: current.id, forceRearm: true)
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

        applyEnabledStateChange(
            to: &updatedAlarm,
            enabled: enabled,
            skipNext: skipNext,
            now: now
        )

        updatedAlarm.lifecycleState = .scheduled

        persistCommittedAlarm(updatedAlarm)

        await cancelRuntimeAlarms(ids: staleManualIDs.subtracting(Set(updatedAlarm.manualScheduleQueue.map(\.id))))
        await AlarmScheduleReconcileEntrypoint.reconcileSchedule(alarmID: updatedAlarm.id, forceRearm: true)
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

    // MARK: - Private CRUD helpers

    func upsertAlarm(existingAlarm: UserAlarm?, draft: AlarmDraft, clearNextOverride: Bool = false) async throws {
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

        let shouldClearOverride = determineShouldClearOverride(
            existingAlarm: existingAlarm,
            nextAlarm: nextAlarm,
            clearNextOverride: clearNextOverride
        )

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

        cleanupWakeCheckIfDisabled(for: id, alarm: nextAlarm)

        persistCommittedAlarm(nextAlarm)

        await cancelRuntimeAlarms(ids: staleManualIDs.subtracting(Set(nextAlarm.manualScheduleQueue.map(\.id))))
        await AlarmScheduleReconcileEntrypoint.reconcileSchedule(alarmID: id, forceRearm: true)
    }

    private func extractOverrideTimeComponents(from draft: AlarmDraft, fallback alarm: UserAlarm) -> (hour: Int, minute: Int) {
        let timeComponents = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: draft.time)
        let hour = timeComponents.hour ?? alarm.hour
        let minute = timeComponents.minute ?? alarm.minute
        return (hour, minute)
    }

    private func applyEnabledStateChange(
        to alarm: inout UserAlarm,
        enabled: Bool,
        skipNext: Bool?,
        now: Date
    ) {
        if enabled {
            alarm.clearTemporaryScheduleOverride(
                restoreEnabledState: true,
                clearManualQueue: true,
                updatedAt: now
            )
        } else if alarm.isRepeating, skipNext == true {
            guard let activation = AlarmSchedulePlanner.activateTemporaryOverride(
                canonicalSchedule: alarm.canonicalScheduleSpec,
                intent: .disableNext,
                now: now,
                manualQueueDepth: manualOverrideQueueDepth
            ) else {
                return
            }

            applyTemporaryScheduleOverrideActivation(
                activation,
                to: &alarm,
                isEnabled: false,
                nextTriggerOverrideDate: nil,
                skipNextUntilDate: activation.overrideState.skippedCanonicalDate,
                updatedAt: now
            )
        } else {
            alarm.clearTemporaryScheduleOverride(
                restoreEnabledState: false,
                clearManualQueue: true,
                updatedAt: now
            )

            if wakeUpCheckController.removeSession(for: alarm.id) != nil {
                wakeUpCheckController.persistSessions()
            }

            persistence.removePendingIDFromAll(alarm.id)
        }
    }

    private func determineShouldClearOverride(
        existingAlarm: UserAlarm?,
        nextAlarm: UserAlarm,
        clearNextOverride: Bool
    ) -> Bool {
        let canonicalScheduleChanged: Bool = if let existingAlarm {
            AlarmSchedulePlanner.shouldClearTemporaryOverride(
                previous: AlarmCanonicalScheduleSignature(spec: existingAlarm.canonicalScheduleSpec),
                next: AlarmCanonicalScheduleSignature(spec: nextAlarm.canonicalScheduleSpec)
            )
        } else {
            false
        }

        return clearNextOverride || canonicalScheduleChanged || !nextAlarm.isRepeating
    }

    private func cleanupWakeCheckIfDisabled(for id: UUID, alarm: UserAlarm) {
        let wakeCheckEnabled = alarm.resolvedSharedSettings(defaults: defaultSharedSettings).wakeUpCheckEnabled
        if !wakeCheckEnabled {
            if wakeUpCheckController.removeSession(for: id) != nil {
                wakeUpCheckController.persistSessions()
            }
            persistence.removePendingID(id, from: .wakeStart)
        }
    }
}
