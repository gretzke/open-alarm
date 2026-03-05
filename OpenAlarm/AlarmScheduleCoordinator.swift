import AlarmKit
import Foundation

/// Owns scheduling reconciliation for all alarms: the three-barrier pipeline
/// (planning -> commit -> convergence) that keeps AlarmKit runtime state in
/// sync with the user's alarm configuration. Extracted from `AlarmStore` to
/// keep alarm CRUD separate from scheduling logic.
@MainActor
final class AlarmScheduleCoordinator {

    // MARK: - Dependencies

    private let alarmManager: AlarmManager
    private let persistence: AlarmPersistence
    private let wakeUpCheckController: WakeUpCheckPipelineController
    private let manualOverrideQueueDepth: Int

    // MARK: - State

    private var pendingRepeatRestores: Set<UUID> = []

    // MARK: - Data access callbacks (set by AlarmStore after init)

    var findAlarm: ((UUID) -> UserAlarm?)!
    var allAlarmIDs: (() -> [UUID])!
    var allAlarms: (() -> [UserAlarm])!
    var defaultSharedSettings: (() -> SharedAlarmSettings)!

    // MARK: - Mutation callbacks (how the coordinator writes back to AlarmStore)

    var persistCommittedAlarm: ((UserAlarm) -> Void)!
    var updateLastKnownState: ((UUID, Alarm.State?) -> Void)!
    var updateRemoteState: ((UUID, Alarm.State?) -> Void)!
    var removeStaleAlarms: ((Set<UUID>) -> Void)!

    // MARK: - Init

    init(
        alarmManager: AlarmManager,
        persistence: AlarmPersistence,
        wakeUpCheckController: WakeUpCheckPipelineController,
        manualOverrideQueueDepth: Int
    ) {
        self.alarmManager = alarmManager
        self.persistence = persistence
        self.wakeUpCheckController = wakeUpCheckController
        self.manualOverrideQueueDepth = manualOverrideQueueDepth
    }

    // MARK: - Owning alarm resolution

    /// Resolves a runtime alarm ID (which may be a manual queue entry ID)
    /// to the owning UserAlarm's ID.
    func owningAlarmID(for runtimeAlarmID: UUID) -> UUID? {
        let alarms = allAlarms()

        if alarms.contains(where: { $0.id == runtimeAlarmID }) {
            return runtimeAlarmID
        }

        return alarms.first(where: { alarm in
            alarm.manualScheduleQueue.contains(where: { $0.id == runtimeAlarmID })
        })?.id
    }

    // MARK: - Reconcile all alarms

    /// Reconciles every user alarm against its canonical + temporary override
    /// scheduling state. This is intentionally called at every lifecycle
    /// opportunity (app open, callback stream, refresh) to keep scheduling
    /// deterministic even after missed callbacks or device restarts.
    private func reconcileAllAlarmSchedules(referenceDate: Date = .now, forceRearm: Bool = false) async {
        // Stale one-shot cleanup: remove expired nap/tryOut alarms that have no
        // runtime entry and whose fixedTriggerDate has passed. This catches cases
        // where the app was not running when the alarm fired (cold path).
        cleanupStaleOneShotAlarms(referenceDate: referenceDate)

        let alarmIDs = allAlarmIDs()
        for alarmID in alarmIDs {
            await reconcileSchedulingForAlarm(alarmID, referenceDate: referenceDate, forceRearm: forceRearm)
        }
    }

    // MARK: - Stale one-shot cleanup

    /// Removes expired nap/tryOut alarms that have no runtime entry.
    ///
    /// This handles the cold-start case where a one-shot alarm fired while the
    /// app was not running, so the normal alerting->non-alerting state transition
    /// was never observed.
    private func cleanupStaleOneShotAlarms(referenceDate: Date = .now) {
        // If the runtime snapshot fails, bail out entirely rather than treating
        // the failure as an empty set--which would incorrectly mark every
        // one-shot alarm as stale and delete it.
        guard let runtimeIDs = runtimeAlarmIDsSnapshot() else {
            return
        }

        let alarms = allAlarms()
        let pendingWakeCheckStartIDs = persistence.loadPendingWakeUpCheckStartIDs()

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
            if runtimeIDs.contains(alarm.id) {
                return false
            }
            // Don't delete alarms that are mid-wake-check arming or already
            // awaiting confirmation.  The StopIntent arm service writes a
            // pending start marker before scheduling the deadline alarm; a
            // concurrent alarmUpdates reconcile can race here between stop()
            // and the deadline re-schedule.
            if pendingWakeCheckStartIDs.contains(alarm.id)
                || wakeUpCheckController.sessionsByAlarmID[alarm.id] != nil
                || alarm.lifecycleState == .awaitingWakeCheck {
                return false
            }
            return true
        }

        guard !staleOneShots.isEmpty else {
            return
        }

        var wakeSessionsChanged = false

        let staleIDs = Set(staleOneShots.map(\.id))

        for alarm in staleOneShots {
            let id = alarm.id
            try? alarmManager.stop(id: id)
            try? alarmManager.cancel(id: id)

            persistence.removePendingIDFromAll(id)

            if wakeUpCheckController.removeSession(for: id) != nil {
                wakeSessionsChanged = true
            }

            updateRemoteState(id, nil)
            updateLastKnownState(id, nil)
        }

        if wakeSessionsChanged {
            wakeUpCheckController.persistSessions()
        }

        removeStaleAlarms(staleIDs)
    }

    // MARK: - Single-alarm three-barrier reconciliation

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
    private func reconcileSchedulingForAlarm(_ alarmID: UUID, referenceDate: Date = .now, forceRearm: Bool = false) async {
        guard let existingAlarm = findAlarm(alarmID) else {
            return
        }

        // Barrier A -- deterministic planning
        let planning = deterministicPlanningBarrier(
            for: existingAlarm,
            referenceDate: referenceDate
        )

        // Barrier B -- state commit
        if planning.didMutatePersistedState {
            persistCommittedAlarm(planning.alarm)
        }

        guard let committedAlarm = findAlarm(alarmID) else {
            return
        }

        // Barrier C -- runtime convergence + repair
        await runtimeConvergenceBarrier(
            for: committedAlarm,
            staleManualRuntimeIDs: planning.staleManualRuntimeIDs,
            referenceDate: referenceDate,
            forceRearm: forceRearm
        )
    }

    // MARK: - Barrier A: Deterministic planning

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
                plannedAlarm.clearTemporaryScheduleOverride(
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
            plannedAlarm.clearTemporaryScheduleOverride(
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

    // MARK: - Barrier C: Runtime convergence

    private func runtimeConvergenceBarrier(
        for alarm: UserAlarm,
        staleManualRuntimeIDs: Set<UUID>,
        referenceDate: Date,
        forceRearm: Bool = false
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

            updateRemoteState(alarm.id, alarm.manualScheduleQueue.isEmpty ? nil : .scheduled)
            return
        }

        if let wakeSession = wakeUpCheckController.sessionsByAlarmID[alarm.id] {
            // Wake-check pipeline owns runtime scheduling while a session exists.
            // Keep recurring reconciliation deterministic, but do not re-arm
            // canonical repeating schedule until confirmation completes.
            //
            // Apply the same healthy-alarm guard as canonical scheduling:
            // do not re-arm a deadline alarm that is already progressing
            // toward fire.  Without this, the alarmUpdates reconcile loop
            // continuously re-schedules the deadline alarm, resetting it
            // back to .scheduled and preventing it from ever reaching
            // .countdown → .alerting.
            if isRuntimeAlarmHealthy(alarm.id) {
                if let runtimeState = runtimeAlarmState(alarm.id) {
                    updateLastKnownState(alarm.id, runtimeState)
                    updateRemoteState(alarm.id, runtimeState)
                }
                return
            }

            // If the deadline has already passed, the alarm already fired.
            // The StopIntent handles advancing to the next cycle via
            // armIfPossible.  Re-arming here with a fallback now+1s date
            // would create a spurious alarm that races with the StopIntent,
            // causing double session creation and eventual pipeline teardown.
            guard wakeSession.deadlineAt > referenceDate else {
                return
            }

            do {
                let config = makeConfiguration(
                    for: alarm,
                    schedule: .fixed(wakeSession.deadlineAt),
                    forceDisableSnooze: WakeUpCheckCoordinator.wakeCheckAlarmsDisableSnooze
                )
                let remote = try await scheduleAlarmWithUpdateFallback(
                    id: alarm.id,
                    configuration: config,
                    isUpdate: true
                )
                updateLastKnownState(alarm.id, remote.state)
                updateRemoteState(alarm.id, remote.state)
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
            // Skip re-scheduling when the alarm is already healthy in the
            // runtime (scheduled, counting down, alerting, or paused/snoozed).
            // Re-arming any of these resets state and prevents firing or
            // discards snooze windows.
            //
            // The only exception is forceRearm + .scheduled: CRUD edits need
            // to overwrite a stale .scheduled entry with the new config.
            if isRuntimeAlarmHealthy(alarm.id) {
                let shouldBypass = forceRearm && runtimeAlarmState(alarm.id) == .scheduled
                if !shouldBypass {
                    if let runtimeState = runtimeAlarmState(alarm.id) {
                        updateLastKnownState(alarm.id, runtimeState)
                        updateRemoteState(alarm.id, runtimeState)
                    }
                    return
                }
            }

            do {
                let resolvedSchedule = AlarmScheduleResolver.runtimeSchedule(for: alarm)
                let config = makeConfiguration(for: alarm, schedule: resolvedSchedule)
                let remote = try await scheduleAlarmWithUpdateFallback(
                    id: alarm.id,
                    configuration: config,
                    isUpdate: true
                )
                updateLastKnownState(alarm.id, remote.state)
                updateRemoteState(alarm.id, remote.state)
            } catch {
                // Best effort. Foreground refresh can recover.
            }
        } else {
            try? alarmManager.stop(id: alarm.id)
            try? alarmManager.cancel(id: alarm.id)
            updateLastKnownState(alarm.id, nil)
            updateRemoteState(alarm.id, nil)
        }
    }

    // MARK: - Manual queue scheduling

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

    private func scheduleManualRuntimeEntry(
        _ manual: AlarmManualScheduleEntry,
        for alarm: UserAlarm
    ) async {
        // Same healthy-alarm guard as canonical scheduling: do not re-arm a
        // manual queue entry that is already progressing toward fire.
        if isRuntimeAlarmHealthy(manual.id) {
            if let runtimeState = runtimeAlarmState(manual.id) {
                updateLastKnownState(manual.id, runtimeState)
            }
            return
        }

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
            updateLastKnownState(manual.id, remote.state)
        } catch {
            // Best effort. Next reconciliation opportunity can recover.
        }
    }

    // MARK: - Canonical suppression

    private func suppressCanonicalRuntimeWhileOverrideActive(
        for alarm: UserAlarm,
        referenceDate: Date
    ) async {
        try? alarmManager.stop(id: alarm.id)
        try? alarmManager.cancel(id: alarm.id)
        updateLastKnownState(alarm.id, nil)

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
            updateLastKnownState(alarm.id, remote.state)
        } catch {
            updateLastKnownState(alarm.id, nil)
        }
    }

    private func canonicalSuppressionFallbackDate(
        for alarm: UserAlarm,
        referenceDate: Date
    ) -> Date {
        let latestManualDate = alarm.manualScheduleQueue.map(\.triggerDate).max() ?? referenceDate
        let baseline = max(latestManualDate, referenceDate)
        return baseline.addingTimeInterval(60)
    }

    // MARK: - Runtime state query

    /// Returns the current AlarmKit runtime state for a single alarm, or nil
    /// if the alarm is not present in the runtime.
    private func runtimeAlarmState(_ alarmID: UUID) -> Alarm.State? {
        guard let runtimeAlarms = try? alarmManager.alarms else {
            return nil
        }
        return runtimeAlarms.first(where: { $0.id == alarmID })?.state
    }

    /// Returns true when the alarm is in a runtime state where re-scheduling must
    /// be suppressed to avoid interrupting active/imminent behaviour.
    ///
    /// Guarded states (re-arming these causes regressions):
    /// - `.scheduled` — alarm is queued at a future time; the busy reconcile loop
    ///   from `alarmUpdates` callbacks would continuously re-arm and prevent the
    ///   `.scheduled` → `.countdown` transition from ever being reached.
    ///   CRUD edits use `forceRearm: true` to bypass this guard for `.scheduled`
    ///   only, ensuring edited alarms still get their new config applied.
    /// - `.countdown` — alarm is imminent; re-arming resets it to .scheduled and
    ///   prevents it from ever reaching alerting while the app is in the foreground.
    /// - `.alerting` — alarm is actively ringing; re-scheduling immediately silences
    ///   the audible alert.
    /// - `.paused` — user has snoozed; re-arming would discard the snooze window.
    private func isRuntimeAlarmHealthy(_ alarmID: UUID) -> Bool {
        guard let state = runtimeAlarmState(alarmID) else {
            return false
        }
        switch state {
        case .scheduled, .countdown, .alerting, .paused:
            return true
        @unknown default:
            return false
        }
    }

    private func runtimeAlarmIDsSnapshot() -> Set<UUID>? {
        guard let runtimeAlarms = try? alarmManager.alarms else {
            return nil
        }

        return Set(runtimeAlarms.map(\.id))
    }

    // MARK: - Repeat restore

    func scheduleRepeatRestore(for alarm: UserAlarm) {
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
                updateLastKnownState(restoredAlarm.id, remote.state)
                updateRemoteState(restoredAlarm.id, remote.state)
            } catch {
                // Best effort; future refresh can recover.
            }
        }
    }

    // MARK: - Bulk cancel

    func cancelRuntimeAlarms(ids: Set<UUID>) async {
        guard !ids.isEmpty else {
            return
        }

        for id in ids {
            try? alarmManager.stop(id: id)
            try? alarmManager.cancel(id: id)
            updateLastKnownState(id, nil)
            updateRemoteState(id, nil)
        }
    }

    // MARK: - Schedule with stop-retry

    func scheduleAlarmWithUpdateFallback(
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

    // MARK: - Configuration factory delegate

    func makeConfiguration(
        for alarm: UserAlarm,
        schedule: Alarm.Schedule,
        forceDisableSnooze: Bool = false,
        runtimeAlarmID: UUID? = nil,
        configReferenceID: UUID? = nil
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        AlarmConfigurationFactory.makeConfiguration(
            for: alarm,
            schedule: schedule,
            defaultSharedSettings: defaultSharedSettings(),
            forceDisableSnooze: forceDisableSnooze,
            runtimeAlarmID: runtimeAlarmID,
            configReferenceID: configReferenceID
        )
    }
}

// MARK: - AlarmScheduleReconcileHandling

extension AlarmScheduleCoordinator: AlarmScheduleReconcileHandling {
    func reconcileSchedule(target: AlarmScheduleReconcileTarget, referenceDate: Date, forceRearm: Bool) async {
        await wakeUpCheckController.reconcileWakeUpCheckPipeline(target: target, referenceDate: referenceDate)

        switch target {
        case let .alarm(runtimeAlarmID):
            guard let alarmID = owningAlarmID(for: runtimeAlarmID) else {
                return
            }
            await reconcileSchedulingForAlarm(alarmID, referenceDate: referenceDate, forceRearm: forceRearm)

        case .allAlarms:
            await reconcileAllAlarmSchedules(referenceDate: referenceDate, forceRearm: forceRearm)
        }
    }
}
