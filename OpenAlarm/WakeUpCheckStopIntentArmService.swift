import AlarmKit
import Foundation
import SwiftUI
import UserNotifications

/// Minimal wake-check arming path for StopIntent execution contexts.
///
/// Why this exists:
/// - StopIntent can run while `AlarmStore` is not alive, so reconcile handler
///   registration is unavailable and app-driven scheduling can no-op.
/// - We still keep durable pending markers in persistence so the app can recover
///   and finish any heavier lifecycle reconciliation on next foreground run.
///
/// TODO(wake-check-phase2): Keep this intent path intentionally small and
/// deterministic. Future challenge-based completion should stay app-driven,
/// while this helper remains focused on immediate wake-check arming only.
@MainActor
enum WakeUpCheckStopIntentArmService {
    static func armIfPossible(
        alarmID: UUID,
        defaults: UserDefaults = .standard,
        referenceDate: Date = .now
    ) async -> Bool {
        let defaultSharedSettings = AlarmPersistence.loadDefaultSharedSettings(from: defaults)
        let alarms = AlarmPersistence.loadUserAlarms(from: defaults)

        guard let alarm = alarms.first(where: { $0.id == alarmID }) else {
            return false
        }

        let resolvedSettings = alarm.resolvedSharedSettings(defaults: defaultSharedSettings)
        let persistedSessions = AlarmPersistence.loadWakeUpCheckSessions(from: defaults)
        let previousSession = persistedSessions.first(where: { $0.alarmID == alarmID })

        let shouldStartCycle = WakeUpCheckCoordinator.shouldEnqueuePipelineOnStopIntent(
            wakeUpCheckEnabledForAlarm: resolvedSettings.wakeUpCheckEnabled,
            hasActiveSession: previousSession != nil
        )

        guard shouldStartCycle else {
            return false
        }

        let notificationCenter = UNUserNotificationCenter.current()
        let notificationSettings = await notificationCenter.notificationSettings()
        guard notificationSettings.authorizationStatus == .authorized else {
            return false
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

        persistArmingAttemptSession(
            nextSession,
            replacingAlarmID: alarmID,
            defaults: defaults
        )

        let notificationService = WakeUpCheckNotificationService(center: notificationCenter)
        notificationService.ensureCategoryRegistered()

        var didScheduleNotification = false

        do {
            try await notificationService.scheduleWakeCheckNotification(for: nextSession)
            didScheduleNotification = true

            try await scheduleWakeCheckRuntimeAlarm(
                for: alarm,
                session: nextSession
            )

            if let previousSession {
                notificationService.cancel(notificationID: previousSession.notificationID)
            }

            markSessionAwaitingConfirmation(
                alarmID: alarmID,
                notificationID: nextSession.notificationID,
                defaults: defaults,
                now: .now
            )
            markAlarmAwaitingWakeCheck(
                alarmID: alarmID,
                referenceDate: referenceDate,
                defaults: defaults
            )
            return true
        } catch {
            if WakeUpCheckCoordinator.shouldCancelNotificationAfterArmingFailure(
                notificationWasScheduled: didScheduleNotification
            ) {
                notificationService.cancel(notificationID: nextSession.notificationID)
            }

            rollbackSessionAfterFailure(
                alarmID: alarmID,
                previousSession: previousSession,
                defaults: defaults
            )
            return false
        }
    }

    private static func persistArmingAttemptSession(
        _ nextSession: WakeUpCheckSessionState,
        replacingAlarmID: UUID,
        defaults: UserDefaults
    ) {
        var sessions = AlarmPersistence.loadWakeUpCheckSessions(from: defaults)
        sessions.removeAll(where: { $0.alarmID == replacingAlarmID })
        sessions.append(nextSession)
        AlarmPersistence.saveWakeUpCheckSessions(sessions, to: defaults)
    }

    private static func rollbackSessionAfterFailure(
        alarmID: UUID,
        previousSession: WakeUpCheckSessionState?,
        defaults: UserDefaults
    ) {
        var sessions = AlarmPersistence.loadWakeUpCheckSessions(from: defaults)
        sessions.removeAll(where: { $0.alarmID == alarmID })

        if let previousSession {
            sessions.append(previousSession)
        }

        AlarmPersistence.saveWakeUpCheckSessions(sessions, to: defaults)
    }

    private static func markSessionAwaitingConfirmation(
        alarmID: UUID,
        notificationID: String,
        defaults: UserDefaults,
        now: Date
    ) {
        var sessions = AlarmPersistence.loadWakeUpCheckSessions(from: defaults)
        guard let sessionIndex = sessions.firstIndex(where: {
            $0.alarmID == alarmID && $0.notificationID == notificationID
        }) else {
            return
        }

        sessions[sessionIndex] = WakeUpCheckStateMachine.markAwaitingConfirmation(
            sessions[sessionIndex],
            now: now
        )
        AlarmPersistence.saveWakeUpCheckSessions(sessions, to: defaults)
    }

    private static func markAlarmAwaitingWakeCheck(
        alarmID: UUID,
        referenceDate: Date,
        defaults: UserDefaults
    ) {
        var alarms = AlarmPersistence.loadUserAlarms(from: defaults)
        guard let alarmIndex = alarms.firstIndex(where: { $0.id == alarmID }) else {
            return
        }

        alarms[alarmIndex].lifecycleState = .awaitingWakeCheck
        alarms[alarmIndex].updatedAt = referenceDate
        AlarmPersistence.saveUserAlarms(alarms, to: defaults)
    }

    private static func scheduleWakeCheckRuntimeAlarm(
        for alarm: UserAlarm,
        session: WakeUpCheckSessionState
    ) async throws {
        let configuration = AlarmConfigurationFactory.wakeCheckConfiguration(
            for: alarm,
            deadlineAt: session.deadlineAt
        )

        do {
            _ = try await AlarmManager.shared.schedule(id: alarm.id, configuration: configuration)
        } catch {
            try? AlarmManager.shared.stop(id: alarm.id)
            _ = try await AlarmManager.shared.schedule(id: alarm.id, configuration: configuration)
        }
    }


}
