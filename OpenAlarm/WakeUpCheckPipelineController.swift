import AlarmKit
import Foundation

/// Manages the wake-up check pipeline lifecycle: starting check cycles,
/// completing checks, and clearing sessions. Extracted from `AlarmStore`
/// to keep alarm CRUD separate from wake-check scheduling logic.
@MainActor
final class WakeUpCheckPipelineController {

    // MARK: - Session state

    private(set) var sessionsByAlarmID: [UUID: WakeUpCheckSessionState] = [:]

    // MARK: - Dependencies

    private let persistence: AlarmPersistence
    private let notificationService: WakeUpCheckNotificationService
    private let alarmManager: AlarmManager

    // MARK: - Data access callbacks (set by AlarmStore after init)

    var findAlarm: ((UUID) -> UserAlarm?)!
    var findAlarmIndex: ((UUID) -> (index: Int, alarm: UserAlarm)?)!
    var allAlarmIDs: (() -> [UUID])!
    var defaultSharedSettings: (() -> SharedAlarmSettings)!
    var notificationPermissionStatus: (() -> NotificationPermissionStatus)!
    var owningAlarmID: ((UUID) -> UUID?)!

    // MARK: - Mutation callbacks (how the controller writes back to AlarmStore)

    var updateAlarm: ((UUID, (inout UserAlarm) -> Void) -> Void)!
    var removeAlarm: ((UUID) -> Void)!
    var sortAndSave: (() -> Void)!
    var updateLastKnownState: ((UUID, _ state: Alarm.State?) -> Void)!
    var updateRemoteState: ((UUID, _ state: Alarm.State?) -> Void)!
    var makeConfiguration: ((UserAlarm, Alarm.Schedule, Bool) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata>)!
    var scheduleAlarmWithUpdateFallback: ((UUID, AlarmManager.AlarmConfiguration<OpenAlarmMetadata>, Bool) async throws -> Alarm)!
    var triggerReconcileForAlarm: ((UUID) -> Void)!

    // MARK: - Init

    init(
        persistence: AlarmPersistence,
        notificationService: WakeUpCheckNotificationService,
        alarmManager: AlarmManager
    ) {
        self.persistence = persistence
        self.notificationService = notificationService
        self.alarmManager = alarmManager
        self.sessionsByAlarmID = Dictionary(
            uniqueKeysWithValues: persistence.loadWakeUpCheckSessions().map { ($0.alarmID, $0) }
        )
    }

    // MARK: - Session mutation helpers (for AlarmStore call sites)

    /// Removes and returns the session for the given alarm, cancelling its notification.
    @discardableResult
    func removeSession(for alarmID: UUID, cancelNotification: Bool = true) -> WakeUpCheckSessionState? {
        guard let session = sessionsByAlarmID.removeValue(forKey: alarmID) else { return nil }
        if cancelNotification {
            notificationService.cancel(notificationID: session.notificationID)
        }
        return session
    }

    /// Updates the session for the given alarm ID directly.
    func setSession(_ session: WakeUpCheckSessionState?, for alarmID: UUID) {
        sessionsByAlarmID[alarmID] = session
    }

    // MARK: - Persistence

    func persistSessions() {
        persistence.saveWakeUpCheckSessions(Array(sessionsByAlarmID.values))
    }

    /// Merges any sessions written to persistence by out-of-band paths
    /// (e.g. `WakeUpCheckStopIntentArmService`) into the in-memory map.
    /// Existing in-memory sessions are preserved (intent path writes are
    /// only picked up when no in-memory entry exists yet).
    private func syncSessionsFromPersistence() {
        let persisted = persistence.loadWakeUpCheckSessions()
        for session in persisted {
            if sessionsByAlarmID[session.alarmID] == nil {
                sessionsByAlarmID[session.alarmID] = session
            }
        }
    }

    // MARK: - Pipeline entry point

    func reconcileWakeUpCheckPipeline(
        target: AlarmScheduleReconcileTarget,
        referenceDate: Date
    ) async {
        // Sync sessions from persistence to pick up out-of-band writes (e.g.
        // from WakeUpCheckStopIntentArmService which writes directly to
        // persistence when AlarmStore is not alive).
        syncSessionsFromPersistence()

        var pendingConfirmIDs = persistence.loadPendingWakeUpCheckConfirmIDs()
        var pendingStartIDs = persistence.loadPendingWakeUpCheckStartIDs()

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

        persistence.savePendingWakeUpCheckConfirmIDs(pendingConfirmIDs)
        persistence.savePendingWakeUpCheckStartIDs(pendingStartIDs)
    }

    // MARK: - Target resolution

    private func wakeUpCheckPipelineAlarmIDs(
        for target: AlarmScheduleReconcileTarget,
        pendingStartIDs: Set<UUID>,
        pendingConfirmIDs: Set<UUID>
    ) -> Set<UUID> {
        switch target {
        case let .alarm(runtimeAlarmID):
            return [owningAlarmID(runtimeAlarmID) ?? runtimeAlarmID]

        case .allAlarms:
            var ids = Set(allAlarmIDs())
            ids.formUnion(sessionsByAlarmID.keys)
            ids.formUnion(pendingStartIDs)
            ids.formUnion(pendingConfirmIDs)
            return ids
        }
    }

    // MARK: - Clear all sessions

    func clearAllWakeUpCheckSessions(restoreSchedules: Bool = false) {
        let affectedAlarmIDs = Set(sessionsByAlarmID.keys)

        for session in sessionsByAlarmID.values {
            notificationService.cancel(notificationID: session.notificationID)
            try? alarmManager.stop(id: session.alarmID)
            try? alarmManager.cancel(id: session.alarmID)
        }

        sessionsByAlarmID.removeAll()
        persistSessions()

        if restoreSchedules {
            for alarmID in affectedAlarmIDs {
                triggerReconcileForAlarm(alarmID)
            }
        }

        var pendingStarts = persistence.loadPendingWakeUpCheckStartIDs()
        if !pendingStarts.isEmpty {
            pendingStarts.removeAll()
            persistence.savePendingWakeUpCheckStartIDs(pendingStarts)
        }

        var pendingConfirm = persistence.loadPendingWakeUpCheckConfirmIDs()
        if !pendingConfirm.isEmpty {
            pendingConfirm.removeAll()
            persistence.savePendingWakeUpCheckConfirmIDs(pendingConfirm)
        }
    }

    // MARK: - Start wake-up check cycle

    func startWakeUpCheckCycle(
        for alarmID: UUID,
        referenceDate: Date
    ) async {
        let previousSession = sessionsByAlarmID[alarmID]

        guard let found = findAlarmIndex(alarmID) else {
            if let previousSession {
                notificationService.cancel(notificationID: previousSession.notificationID)
                sessionsByAlarmID.removeValue(forKey: alarmID)
                persistSessions()
            }
            return
        }

        let alarm = found.alarm
        let resolvedSettings = alarm.resolvedSharedSettings(defaults: defaultSharedSettings())
        let shouldStartCycle = WakeUpCheckCoordinator.shouldEnqueuePipelineOnStopIntent(
            wakeUpCheckEnabledForAlarm: resolvedSettings.wakeUpCheckEnabled,
            hasActiveSession: previousSession != nil
        )

        guard shouldStartCycle else {
            return
        }

        guard notificationPermissionStatus() == .authorized else {
            if let previousSession {
                notificationService.cancel(notificationID: previousSession.notificationID)
                sessionsByAlarmID.removeValue(forKey: alarmID)
                persistSessions()
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
            notificationService.cancel(notificationID: previousSession.notificationID)
        }

        sessionsByAlarmID[alarmID] = nextSession
        persistSessions()

        updateAlarm(alarmID) { alarm in
            if alarm.lifecycleState != .awaitingWakeCheck {
                alarm.lifecycleState = .awaitingWakeCheck
                alarm.updatedAt = referenceDate
            }
        }
        sortAndSave()

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            guard let latestAlarm = findAlarm(alarmID) else {
                if sessionsByAlarmID[alarmID]?.notificationID == nextSession.notificationID {
                    sessionsByAlarmID.removeValue(forKey: alarmID)
                    persistSessions()
                }
                return
            }

            var didScheduleWakeCheckNotification = false

            do {
                try await notificationService.scheduleWakeCheckNotification(for: nextSession)
                didScheduleWakeCheckNotification = true

                let config = makeConfiguration(
                    latestAlarm,
                    .fixed(nextSession.deadlineAt),
                    WakeUpCheckCoordinator.wakeCheckAlarmsDisableSnooze
                )
                let remoteAlarm = try await scheduleAlarmWithUpdateFallback(
                    latestAlarm.id,
                    config,
                    true
                )

                updateLastKnownState(latestAlarm.id, remoteAlarm.state)
                updateRemoteState(latestAlarm.id, remoteAlarm.state)

                if let latestSession = sessionsByAlarmID[latestAlarm.id],
                   latestSession.notificationID == nextSession.notificationID {
                    sessionsByAlarmID[latestAlarm.id] = WakeUpCheckStateMachine.markAwaitingConfirmation(
                        latestSession,
                        now: .now
                    )
                    persistSessions()
                }
            } catch {
                if sessionsByAlarmID[alarmID]?.notificationID == nextSession.notificationID {
                    if WakeUpCheckCoordinator.shouldCancelNotificationAfterArmingFailure(
                        notificationWasScheduled: didScheduleWakeCheckNotification
                    ) {
                        notificationService.cancel(notificationID: nextSession.notificationID)
                    }

                    sessionsByAlarmID.removeValue(forKey: alarmID)
                    persistSessions()
                }

                await applyWakeUpCheckArmingFailureResolution(
                    for: alarmID,
                    referenceDate: .now
                )
            }
        }
    }

    // MARK: - Arming failure resolution

    func applyWakeUpCheckArmingFailureResolution(
        for alarmID: UUID,
        referenceDate: Date
    ) async {
        guard let found = findAlarmIndex(alarmID) else {
            return
        }

        let resolution = WakeUpCheckCoordinator.armingFailureResolution(
            isRepeating: found.alarm.isRepeating,
            hasActiveSessionAfterAttempt: sessionsByAlarmID[alarmID] != nil
        )

        switch resolution {
        case .keepAwaitingActiveSession:
            return

        case .restoreScheduled:
            updateAlarm(alarmID) { alarm in
                if alarm.lifecycleState != .scheduled {
                    alarm.lifecycleState = .scheduled
                    alarm.updatedAt = referenceDate
                }
            }
            sortAndSave()

        case .completeNonRepeating:
            await completeWakeUpCheck(for: alarmID)
        }
    }

    // MARK: - Complete wake-up check

    func completeWakeUpCheck(for alarmID: UUID) async {
        if let session = sessionsByAlarmID.removeValue(forKey: alarmID) {
            notificationService.cancel(notificationID: session.notificationID)
            persistSessions()
        }

        guard let found = findAlarmIndex(alarmID) else {
            return
        }

        var alarm = found.alarm
        alarm.snoozeCount = 0
        alarm.updatedAt = .now

        try? alarmManager.stop(id: alarmID)
        try? alarmManager.cancel(id: alarmID)
        updateRemoteState(alarmID, nil)
        updateLastKnownState(alarmID, nil)

        persistence.removePendingIDFromAll(alarmID)

        if alarm.isRepeating, alarm.isEnabled {
            alarm.lifecycleState = .scheduled
            updateAlarm(alarmID) { $0 = alarm }
            sortAndSave()

            do {
                let resolvedSchedule = AlarmScheduleResolver.runtimeSchedule(for: alarm)
                let config = makeConfiguration(alarm, resolvedSchedule, false)
                let remote = try await scheduleAlarmWithUpdateFallback(
                    alarm.id,
                    config,
                    true
                )
                updateLastKnownState(alarm.id, remote.state)
                updateRemoteState(alarm.id, remote.state)
            } catch {
                // Best effort. Foreground refresh can recover.
            }
            return
        }

        alarm.lifecycleState = .completed

        if alarm.deleteAfterUse {
            removeAlarm(alarmID)
        } else {
            alarm.isEnabled = false
            alarm.skipNextUntilDate = nil
            alarm.nextTriggerOverrideDate = nil
            updateAlarm(alarmID) { $0 = alarm }
        }

        sortAndSave()
    }
}
