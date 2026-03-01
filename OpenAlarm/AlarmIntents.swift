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
        let pendingConfirmIDs = AlarmPersistence.loadPendingWakeUpCheckConfirmIDs(from: defaults)
        let hasPendingWakeCheckConfirmation = pendingConfirmIDs.contains(id)

        let shouldEnqueueWakeCheckStart = WakeUpCheckCoordinator.shouldEnqueuePipelineOnStopIntent(
            wakeUpCheckEnabledForAlarm: hasWakeCheckEnabled,
            hasActiveSession: hasActiveWakeCheckSession,
            hasPendingConfirmation: hasPendingWakeCheckConfirmation
        )

        var pendingStarts = AlarmPersistence.loadPendingWakeUpCheckStartIDs(from: defaults)
        if shouldEnqueueWakeCheckStart {
            pendingStarts.insert(id)
        } else if hasPendingWakeCheckConfirmation {
            // Confirm-awake is terminal for the in-flight cycle. Any stale
            // pending-start marker for the same alarm must be cleared.
            pendingStarts.remove(id)
        }
        AlarmPersistence.savePendingWakeUpCheckStartIDs(pendingStarts, to: defaults)

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
            alarms[index] = alarm
            AlarmPersistence.saveUserAlarms(alarms, to: defaults)

            let snoozeDate = Date.now.addingTimeInterval(snoozeInterval(for: effectiveSharedSettings.snoozeDurationMinutes))

            do {
                // Preferred path: replace configuration first, then dismiss current alert.
                let config = makeConfiguration(
                    for: alarm,
                    schedule: .fixed(snoozeDate),
                    isShadowTrial: false,
                    defaultSharedSettings: defaultSharedSettings
                )
                _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
                try AlarmManager.shared.stop(id: id)
            } catch {
                do {
                    // Recovery path: stop current alert first, then reschedule with updated config.
                    try AlarmManager.shared.stop(id: id)
                    let config = makeConfiguration(
                        for: alarm,
                        schedule: .fixed(snoozeDate),
                        isShadowTrial: false,
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

        var trials = AlarmPersistence.loadShadowTrials(from: defaults)
        if let index = trials.firstIndex(where: { $0.id == id }) {
            var trial = trials[index]

            guard trial.canSnoozeAgain else {
                pending.remove(id)
                AlarmPersistence.savePendingSnoozeIDs(pending, to: defaults)
                try AlarmManager.shared.stop(id: id)
                try AlarmManager.shared.cancel(id: id)
                trials.remove(at: index)
                AlarmPersistence.saveShadowTrials(trials, to: defaults)
                await reconcileSchedule()
                return .result()
            }

            trial.snoozeCount += 1
            trial.updatedAt = .now
            trials[index] = trial
            AlarmPersistence.saveShadowTrials(trials, to: defaults)

            let snoozeDate = Date.now.addingTimeInterval(snoozeInterval(for: trial.snoozeDurationMinutes))

            do {
                // Preferred path: replace configuration first, then dismiss current alert.
                let config = makeConfiguration(for: trial, schedule: .fixed(snoozeDate))
                _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
                try AlarmManager.shared.stop(id: id)
            } catch {
                do {
                    // Recovery path: stop current alert first, then reschedule with updated config.
                    try AlarmManager.shared.stop(id: id)
                    let config = makeConfiguration(for: trial, schedule: .fixed(snoozeDate))
                    _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
                } catch {
                    pending.remove(id)
                    AlarmPersistence.savePendingSnoozeIDs(pending, to: defaults)
                    try? AlarmManager.shared.countdown(id: id)
                }
            }
            await reconcileSchedule()
            return .result()
        }

        if var nap = AlarmPersistence.loadActiveNapSession(from: defaults), nap.id == id {
            let effectiveSharedSettings = nap.resolvedSharedSettings(defaults: defaultSharedSettings)

            guard effectiveSharedSettings.canSnoozeAgain(currentCount: nap.snoozeCount) else {
                pending.remove(id)
                AlarmPersistence.savePendingSnoozeIDs(pending, to: defaults)
                try AlarmManager.shared.stop(id: id)
                await reconcileSchedule()
                return .result()
            }

            nap.snoozeCount += 1
            nap.pausedRemainingSeconds = nil
            nap.updatedAt = .now

            let snoozeDate = Date.now.addingTimeInterval(snoozeInterval(for: effectiveSharedSettings.snoozeDurationMinutes))
            nap.targetDate = snoozeDate
            AlarmPersistence.saveActiveNapSession(nap, to: defaults)

            do {
                let config = makeConfiguration(for: nap, schedule: .fixed(snoozeDate), defaultSharedSettings: defaultSharedSettings)
                _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
                try AlarmManager.shared.stop(id: id)
            } catch {
                do {
                    try AlarmManager.shared.stop(id: id)
                    let config = makeConfiguration(for: nap, schedule: .fixed(snoozeDate), defaultSharedSettings: defaultSharedSettings)
                    _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
                } catch {
                    pending.remove(id)
                    AlarmPersistence.savePendingSnoozeIDs(pending, to: defaults)
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

    private func makeConfiguration(
        for alarm: UserAlarm,
        schedule: Alarm.Schedule,
        isShadowTrial: Bool,
        defaultSharedSettings: SharedAlarmSettings
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let sharedSettings = alarm.resolvedSharedSettings(defaults: defaultSharedSettings)
        let showSnoozeButton = sharedSettings.canSnoozeAgain(currentCount: alarm.snoozeCount)

        let alertPresentation = AlarmPresentation.Alert(
            title: localizedResource(from: resolvedAlarmTitle(from: alarm.name)),
            stopButton: .stopButton,
            secondaryButton: showSnoozeButton ? .snoozeButton : nil,
            secondaryButtonBehavior: showSnoozeButton ? .custom : nil
        )

        let presentation = AlarmPresentation(alert: alertPresentation)
        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: OpenAlarmMetadata(source: alarm.id.uuidString, isShadowTrial: isShadowTrial),
            tintColor: Color(red: 100 / 255, green: 210 / 255, blue: 255 / 255)
        )

        let secondaryIntent: (any LiveActivityIntent)? = if showSnoozeButton {
            SnoozeIntent(alarmID: alarm.id.uuidString)
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
            stopIntent: StopIntent(alarmID: alarm.id.uuidString),
            secondaryIntent: secondaryIntent,
            sound: .default
        )
    }

    private func makeConfiguration(
        for trial: ShadowTrialAlarm,
        schedule: Alarm.Schedule
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let showSnoozeButton = trial.canSnoozeAgain

        let alertPresentation = AlarmPresentation.Alert(
            title: localizedResource(from: resolvedAlarmTitle(from: trial.name)),
            stopButton: .stopButton,
            secondaryButton: showSnoozeButton ? .snoozeButton : nil,
            secondaryButtonBehavior: showSnoozeButton ? .custom : nil
        )

        let presentation = AlarmPresentation(alert: alertPresentation)
        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: OpenAlarmMetadata(source: trial.id.uuidString, isShadowTrial: true),
            tintColor: Color(red: 100 / 255, green: 210 / 255, blue: 255 / 255)
        )

        let secondaryIntent: (any LiveActivityIntent)? = if showSnoozeButton {
            SnoozeIntent(alarmID: trial.id.uuidString)
        } else {
            nil
        }

        let countdownDuration: Alarm.CountdownDuration? = if showSnoozeButton {
            .init(preAlert: nil, postAlert: snoozeInterval(for: trial.snoozeDurationMinutes))
        } else {
            nil
        }

        return .init(
            countdownDuration: countdownDuration,
            schedule: schedule,
            attributes: attributes,
            stopIntent: StopIntent(alarmID: trial.id.uuidString),
            secondaryIntent: secondaryIntent,
            sound: .default
        )
    }

    private func makeConfiguration(
        for nap: NapAlarmSession,
        schedule: Alarm.Schedule,
        defaultSharedSettings: SharedAlarmSettings
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let sharedSettings = nap.resolvedSharedSettings(defaults: defaultSharedSettings)
        let showSnoozeButton = sharedSettings.canSnoozeAgain(currentCount: nap.snoozeCount)

        let alertPresentation = AlarmPresentation.Alert(
            title: localizedResource(from: String(localized: "nap_default_alarm_label")),
            stopButton: .stopButton,
            secondaryButton: showSnoozeButton ? .snoozeButton : nil,
            secondaryButtonBehavior: showSnoozeButton ? .custom : nil
        )

        let presentation = AlarmPresentation(alert: alertPresentation)
        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: OpenAlarmMetadata(source: nap.id.uuidString, isShadowTrial: false),
            tintColor: Color(red: 100 / 255, green: 210 / 255, blue: 255 / 255)
        )

        let secondaryIntent: (any LiveActivityIntent)? = if showSnoozeButton {
            SnoozeIntent(alarmID: nap.id.uuidString)
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
            stopIntent: StopIntent(alarmID: nap.id.uuidString),
            secondaryIntent: secondaryIntent,
            sound: .default
        )
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
}
