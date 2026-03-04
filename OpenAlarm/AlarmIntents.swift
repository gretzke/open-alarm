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
        var pending = AlarmPersistence.loadPendingSnoozeIDs(from: defaults)
        if pending.remove(id) != nil {
            AlarmPersistence.savePendingSnoozeIDs(pending, to: defaults)
        }

        let defaultSharedSettings = AlarmPersistence.loadDefaultSharedSettings(from: defaults)
        let alarms = AlarmPersistence.loadUserAlarms(from: defaults)
        let hasWakeCheckEnabled = alarms
            .first(where: { $0.id == id })?
            .resolvedSharedSettings(defaults: defaultSharedSettings)
            .wakeUpCheckEnabled ?? false
        let hasActiveWakeCheckSession = AlarmPersistence
            .loadWakeUpCheckSessions(from: defaults)
            .contains(where: { $0.alarmID == id })

        let shouldEnqueueWakeCheckStart = WakeUpCheckCoordinator.shouldEnqueuePipelineOnStopIntent(
            wakeUpCheckEnabledForAlarm: hasWakeCheckEnabled,
            hasActiveSession: hasActiveWakeCheckSession
        )

        if shouldEnqueueWakeCheckStart {
            var pendingStarts = AlarmPersistence.loadPendingWakeUpCheckStartIDs(from: defaults)
            pendingStarts.insert(id)
            AlarmPersistence.savePendingWakeUpCheckStartIDs(pendingStarts, to: defaults)
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
                pendingStartIDs: AlarmPersistence.loadPendingWakeUpCheckStartIDs(from: defaults),
                alarmID: id,
                didArmImmediately: didArmWakeCheckImmediately
            )
            AlarmPersistence.savePendingWakeUpCheckStartIDs(pendingStartsAfterImmediateArming, to: defaults)
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
        let defaultSharedSettings = AlarmPersistence.loadDefaultSharedSettings(from: defaults)

        var pending = AlarmPersistence.loadPendingSnoozeIDs(from: defaults)
        pending.insert(id)
        AlarmPersistence.savePendingSnoozeIDs(pending, to: defaults)

        var alarms = AlarmPersistence.loadUserAlarms(from: defaults)
        if let index = alarms.firstIndex(where: { $0.id == id }) {
            var alarm = alarms[index]
            let effectiveSharedSettings = alarm.resolvedSharedSettings(defaults: defaultSharedSettings)

            guard effectiveSharedSettings.canSnoozeAgain(currentCount: alarm.snoozeCount) else {
                pending.remove(id)
                AlarmPersistence.savePendingSnoozeIDs(pending, to: defaults)
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
            AlarmPersistence.saveUserAlarms(alarms, to: defaults)

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
                    AlarmPersistence.savePendingSnoozeIDs(pending, to: defaults)
                    // Last fallback: keep snooze behavior even if config replacement failed.
                    try? AlarmManager.shared.countdown(id: id)
                }
            }
            await reconcileSchedule()
            return .result()
        }

        pending.remove(id)
        AlarmPersistence.savePendingSnoozeIDs(pending, to: defaults)
        try AlarmManager.shared.stop(id: id)
        await reconcileSchedule()
        return .result()
    }


}
