import AlarmKit
import Foundation

// MARK: - Nap lifecycle (create / pause / resume / delete)

extension AlarmStore {

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

    /// Reconciles the active nap alarm's state against remote AlarmKit state.
    /// Handles remote-initiated pause/resume and expiry cleanup.
    /// Returns true if `updated` was mutated.
    func handleActiveNap(
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

        updateNapRemoteTracking(napID: napID, nap: nap, currentState: currentState)

        if let result = handleNapCompletionOrExpiry(
            nap: nap,
            napIndex: napIndex,
            previousState: previousState,
            currentState: currentState,
            pendingSnoozeIDs: &pendingSnoozeIDs,
            updated: &updated
        ) {
            return result
        }

        if let result = handleNapPauseResumeSync(
            nap: &nap,
            napIndex: napIndex,
            currentState: currentState,
            updated: &updated
        ) {
            return result
        }

        return false
    }

    // MARK: - Private nap helpers

    private func updateNapRemoteTracking(napID: UUID, nap: UserAlarm, currentState: Alarm.State?) {
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
    }

    private func handleNapCompletionOrExpiry(
        nap: UserAlarm,
        napIndex: Int,
        previousState: Alarm.State?,
        currentState: Alarm.State?,
        pendingSnoozeIDs: inout Set<UUID>,
        updated: inout [UserAlarm]
    ) -> Bool? {
        let napID = nap.id

        // Nap completed (alert → non-alert transition)
        if previousState == .alerting, currentState != .alerting {
            pendingSnoozeIDs.remove(napID)
            remoteStates.removeValue(forKey: napID)
            lastKnownAlarmState.removeValue(forKey: napID)
            updated.remove(at: napIndex)
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

        return nil
    }

    private func handleNapPauseResumeSync(
        nap: inout UserAlarm,
        napIndex: Int,
        currentState: Alarm.State?,
        updated: inout [UserAlarm]
    ) -> Bool? {
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

        return nil
    }

    func rescheduleActiveNap() async {
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
}
