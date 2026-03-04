import AlarmKit
import Foundation

// MARK: - Remote alarm state synchronization

extension AlarmStore {

    func applyRemoteAlarms(_ incoming: [Alarm]) {
        let remoteByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        let referenceDate = Date.now

        var pendingSnoozeIDs = persistence.loadPendingSnoozeIDs()
        let originalPending = pendingSnoozeIDs

        var updated = alarms
        var changed = mergeSnoozeCountsFromPersistence(into: &updated)

        var idsToAutoDelete: Set<UUID> = []

        for index in updated.indices {
            var alarm = updated[index]

            if alarm.temporaryScheduleOverride != nil {
                let result = reconcileOverrideAlarm(
                    alarm: &alarm,
                    remoteByID: remoteByID,
                    pendingSnoozeIDs: &pendingSnoozeIDs,
                    referenceDate: referenceDate,
                    changed: &changed
                )
                updated[index] = alarm
                if result == .continue { continue }
            }

            reconcileStandardAlarm(
                alarm: &alarm,
                remoteByID: remoteByID,
                pendingSnoozeIDs: &pendingSnoozeIDs,
                idsToAutoDelete: &idsToAutoDelete,
                referenceDate: referenceDate,
                changed: &changed
            )
            updated[index] = alarm
        }

        processAutoDeletes(
            idsToAutoDelete: idsToAutoDelete,
            pendingSnoozeIDs: &pendingSnoozeIDs,
            updated: &updated,
            changed: &changed
        )

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

    // MARK: - Override alarm reconciliation

    private enum ReconcileResult {
        case `continue`
        case fallthrough_
    }

    private func reconcileOverrideAlarm(
        alarm: inout UserAlarm,
        remoteByID: [UUID: Alarm],
        pendingSnoozeIDs: inout Set<UUID>,
        referenceDate: Date,
        changed: inout Bool
    ) -> ReconcileResult {
        guard let overrideState = alarm.temporaryScheduleOverride else {
            return .fallthrough_
        }

        guard !alarm.manualScheduleQueue.isEmpty else {
            alarm.clearTemporaryScheduleOverride(
                restoreEnabledState: true,
                clearManualQueue: false,
                updatedAt: referenceDate
            )
            alarm.lifecycleState = .scheduled
            changed = true
            return .continue
        }

        var shouldRestoreRecurring = false
        var shouldConsumeOverrideDate = false
        var hasManualAlertingState = false

        for manual in alarm.manualScheduleQueue {
            let previousState = lastKnownAlarmState[manual.id]
            let currentState = remoteByID[manual.id]?.state

            updateLastKnownState(for: manual.id, currentState: currentState)

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
            restoreRecurringAfterOverride(
                alarm: &alarm,
                pendingSnoozeIDs: &pendingSnoozeIDs,
                referenceDate: referenceDate,
                changed: &changed
            )
        } else {
            applyManualAlertingLifecycle(
                alarm: &alarm,
                hasManualAlertingState: hasManualAlertingState,
                changed: &changed
            )
        }

        return .continue
    }

    private func restoreRecurringAfterOverride(
        alarm: inout UserAlarm,
        pendingSnoozeIDs: inout Set<UUID>,
        referenceDate: Date,
        changed: inout Bool
    ) {
        for id in alarm.manualScheduleQueue.map(\.id) {
            pendingSnoozeIDs.remove(id)
        }

        alarm.clearTemporaryScheduleOverride(
            restoreEnabledState: true,
            clearManualQueue: false,
            updatedAt: referenceDate
        )
        alarm.lifecycleState = .scheduled
        remoteStates.removeValue(forKey: alarm.id)
        changed = true
    }

    private func applyManualAlertingLifecycle(
        alarm: inout UserAlarm,
        hasManualAlertingState: Bool,
        changed: inout Bool
    ) {
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

    // MARK: - Standard alarm reconciliation

    private func reconcileStandardAlarm(
        alarm: inout UserAlarm,
        remoteByID: [UUID: Alarm],
        pendingSnoozeIDs: inout Set<UUID>,
        idsToAutoDelete: inout Set<UUID>,
        referenceDate: Date,
        changed: inout Bool
    ) {
        // Skip alarms still in override mode (handled above).
        guard alarm.temporaryScheduleOverride == nil else { return }

        let alarmID = alarm.id
        let previousState = lastKnownAlarmState[alarmID]
        let currentState = remoteByID[alarmID]?.state

        updateRemoteTracking(for: alarmID, currentState: currentState)

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
            return
        }

        _ = applyRecurringScheduleReconciliation(
            alarm: &alarm,
            previousState: previousState,
            currentState: currentState,
            changed: &changed
        )

        guard let currentState else { return }

        applyLifecycleFromCurrentState(
            alarm: &alarm,
            currentState: currentState,
            referenceDate: referenceDate,
            changed: &changed
        )
    }

    private func applyLifecycleFromCurrentState(
        alarm: inout UserAlarm,
        currentState: Alarm.State,
        referenceDate: Date,
        changed: inout Bool
    ) {
        switch currentState {
        case .alerting:
            if let session = wakeUpCheckController.sessionsByAlarmID[alarm.id],
               session.status != .deadlineFired {
                wakeUpCheckController.setSession(
                    WakeUpCheckStateMachine.markDeadlineFired(session, now: referenceDate),
                    for: alarm.id
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
    }

    // MARK: - Auto-delete processing

    private func processAutoDeletes(
        idsToAutoDelete: Set<UUID>,
        pendingSnoozeIDs: inout Set<UUID>,
        updated: inout [UserAlarm],
        changed: inout Bool
    ) {
        guard !idsToAutoDelete.isEmpty else { return }

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

    // MARK: - Tracking helpers

    private func updateLastKnownState(for id: UUID, currentState: Alarm.State?) {
        if let currentState {
            lastKnownAlarmState[id] = currentState
        } else {
            lastKnownAlarmState.removeValue(forKey: id)
        }
    }

    private func updateRemoteTracking(for alarmID: UUID, currentState: Alarm.State?) {
        if let currentState {
            lastKnownAlarmState[alarmID] = currentState
            remoteStates[alarmID] = currentState
        } else {
            lastKnownAlarmState.removeValue(forKey: alarmID)
            remoteStates.removeValue(forKey: alarmID)
        }
    }

    // MARK: - Post-alert transition

    func applyPostAlertTransition(
        alarm: inout UserAlarm,
        previousState: Alarm.State?,
        currentState: Alarm.State?,
        pendingSnoozeIDs: inout Set<UUID>,
        idsToAutoDelete: inout Set<UUID>,
        changed: inout Bool
    ) {
        if pendingSnoozeIDs.contains(alarm.id) {
            if alarm.lifecycleState != .scheduled {
                alarm.lifecycleState = .scheduled
                changed = true
            }
            return
        }

        let hadSnoozes = alarm.snoozeCount > 0
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
            applyRepeatingPostAlertTransition(
                alarm: &alarm,
                previousState: previousState,
                currentState: currentState,
                hadSnoozes: hadSnoozes,
                wakeCheckEnabled: wakeCheckEnabled,
                changed: &changed
            )
            return
        }

        applyNonRepeatingPostAlertCompletion(
            alarm: &alarm,
            wakeCheckEnabled: wakeCheckEnabled,
            idsToAutoDelete: &idsToAutoDelete,
            changed: &changed
        )
    }

    private func applyRepeatingPostAlertTransition(
        alarm: inout UserAlarm,
        previousState: Alarm.State?,
        currentState: Alarm.State?,
        hadSnoozes: Bool,
        wakeCheckEnabled: Bool,
        changed: inout Bool
    ) {
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

        if alarm.lifecycleState != .scheduled {
            alarm.lifecycleState = .scheduled
            changed = true
        }
    }

    private func applyNonRepeatingPostAlertCompletion(
        alarm: inout UserAlarm,
        wakeCheckEnabled: Bool,
        idsToAutoDelete: inout Set<UUID>,
        changed: inout Bool
    ) {
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

    // MARK: - Recurring schedule reconciliation

    func applyRecurringScheduleReconciliation(
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
                if allowRecurringRestore, alarm.isEnabled {
                    scheduleCoordinator.scheduleRepeatRestore(for: alarm)
                }
            }
        }

        return operations
    }
}
