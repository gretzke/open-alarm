import AlarmKit
import AppIntents
import Foundation
import SwiftUI

struct StopIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop"
    static var description = IntentDescription("Stop an alarm")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "alarmID")
    var alarmID: String

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    init() {
        self.alarmID = ""
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else {
            return .result()
        }

        let defaults = UserDefaults.standard
        let persistence = AlarmPersistence(defaults: defaults)

        persistence.removePendingID(id, from: .snooze)

        let defaultSharedSettings = persistence.loadDefaultSharedSettings()
        let alarms = persistence.loadUserAlarms()
        let hasWakeCheckEnabled = alarms
            .first(where: { $0.id == id })?
            .resolvedSharedSettings(defaults: defaultSharedSettings)
            .wakeUpCheckEnabled ?? false
        let hasActiveWakeCheckSession = persistence
            .loadWakeUpCheckSessions()
            .contains(where: { $0.alarmID == id })

        let shouldEnqueueWakeCheckStart = WakeUpCheckCoordinator.shouldEnqueuePipelineOnStopIntent(
            wakeUpCheckEnabledForAlarm: hasWakeCheckEnabled,
            hasActiveSession: hasActiveWakeCheckSession
        )

        if shouldEnqueueWakeCheckStart {
            var pendingStarts = persistence.loadPendingWakeUpCheckStartIDs()
            pendingStarts.insert(id)
            persistence.savePendingWakeUpCheckStartIDs(pendingStarts)
        }

        try? AlarmManager.shared.stop(id: id)

        if shouldEnqueueWakeCheckStart {
            // Intent execution can happen when AlarmStore/reconcile handler is absent.
            // Perform a minimal immediate arming attempt here, while keeping the
            // durable pending marker as fallback if this short path cannot finish.
            let didArmWakeCheckImmediately = await WakeUpCheckStopIntentArmService.armIfPossible(
                alarmID: id,
                defaults: defaults
            )
            let pendingStartsAfterImmediateArming = WakeUpCheckCoordinator.pendingStartIDsAfterImmediateStopIntentArming(
                pendingStartIDs: persistence.loadPendingWakeUpCheckStartIDs(),
                alarmID: id,
                didArmImmediately: didArmWakeCheckImmediately
            )
            persistence.savePendingWakeUpCheckStartIDs(pendingStartsAfterImmediateArming)
        }

        await AlarmScheduleReconcileEntrypoint.reconcile(trigger: .stopIntent(id))
        return .result()
    }
}

struct SnoozeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Snooze"
    static var description = IntentDescription("Snooze an alarm")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "alarmID")
    var alarmID: String

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    init() {
        self.alarmID = ""
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else {
            return .result()
        }

        func reconcileSchedule() async {
            await AlarmScheduleReconcileEntrypoint.reconcile(trigger: .snoozeIntent(id))
        }

        let defaults = UserDefaults.standard
        let persistence = AlarmPersistence(defaults: defaults)

        let defaultSharedSettings = persistence.loadDefaultSharedSettings()

        var pending = persistence.loadPendingSnoozeIDs()
        pending.insert(id)
        persistence.savePendingSnoozeIDs(pending)

        var alarms = persistence.loadUserAlarms()
        if let index = alarms.firstIndex(where: { $0.id == id }) {
            var alarm = alarms[index]
            let effectiveSharedSettings = alarm.resolvedSharedSettings(defaults: defaultSharedSettings)

            guard effectiveSharedSettings.canSnoozeAgain(currentCount: alarm.snoozeCount) else {
                pending.remove(id)
                persistence.savePendingSnoozeIDs(pending)
                try AlarmManager.shared.stop(id: id)
                await reconcileSchedule()
                return .result()
            }

            alarm.snoozeCount += 1
            alarm.updatedAt = .now

            // For nap alarms, update the countdown target and clear pause state.
            if alarm.isNap {
                let snoozeSeconds = AlarmConfigurationFactory.snoozeInterval(for: effectiveSharedSettings.snoozeDurationMinutes)
                alarm.fixedTriggerDate = Date.now.addingTimeInterval(snoozeSeconds)
                alarm.pausedRemainingSeconds = nil
            }

            alarms[index] = alarm
            persistence.saveUserAlarms(alarms)

            let snoozeDate = Date.now.addingTimeInterval(AlarmConfigurationFactory.snoozeInterval(for: effectiveSharedSettings.snoozeDurationMinutes))

            do {
                // Preferred path: replace configuration first, then dismiss current alert.
                let config = AlarmConfigurationFactory.makeConfiguration(
                    for: alarm,
                    schedule: .fixed(snoozeDate),
                    defaultSharedSettings: defaultSharedSettings
                )
                _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
                try AlarmManager.shared.stop(id: id)
            } catch {
                do {
                    // Recovery path: stop current alert first, then reschedule with updated config.
                    try AlarmManager.shared.stop(id: id)
                    let config = AlarmConfigurationFactory.makeConfiguration(
                        for: alarm,
                        schedule: .fixed(snoozeDate),
                        defaultSharedSettings: defaultSharedSettings
                    )
                    _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
                } catch {
                    pending.remove(id)
                    persistence.savePendingSnoozeIDs(pending)
                    // Last fallback: keep snooze behavior even if config replacement failed.
                    try? AlarmManager.shared.countdown(id: id)
                }
            }
            await reconcileSchedule()
            return .result()
        }

        pending.remove(id)
        persistence.savePendingSnoozeIDs(pending)
        try AlarmManager.shared.stop(id: id)
        await reconcileSchedule()
        return .result()
    }


}
