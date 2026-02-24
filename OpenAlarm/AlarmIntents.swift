import AlarmKit
import AppIntents
import Foundation
import SwiftUI

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

        let defaults = UserDefaults.standard

        var pending = AlarmPersistence.loadPendingSnoozeIDs(from: defaults)
        pending.insert(id)
        AlarmPersistence.savePendingSnoozeIDs(pending, to: defaults)

        var alarms = AlarmPersistence.loadUserAlarms(from: defaults)
        if let index = alarms.firstIndex(where: { $0.id == id }) {
            var alarm = alarms[index]

            guard alarm.canSnoozeAgain else {
                pending.remove(id)
                AlarmPersistence.savePendingSnoozeIDs(pending, to: defaults)
                try AlarmManager.shared.stop(id: id)
                return .result()
            }

            alarm.snoozeCount += 1
            alarm.updatedAt = .now
            alarms[index] = alarm
            AlarmPersistence.saveUserAlarms(alarms, to: defaults)

            let snoozeDate = Date.now.addingTimeInterval(snoozeInterval(for: alarm.snoozeDurationMinutes))

            do {
                // Preferred path: replace configuration first, then dismiss current alert.
                let config = makeConfiguration(for: alarm, schedule: .fixed(snoozeDate), isShadowTrial: false)
                _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
                try AlarmManager.shared.stop(id: id)
            } catch {
                do {
                    // Recovery path: stop current alert first, then reschedule with updated config.
                    try AlarmManager.shared.stop(id: id)
                    let config = makeConfiguration(for: alarm, schedule: .fixed(snoozeDate), isShadowTrial: false)
                    _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
                } catch {
                    pending.remove(id)
                    AlarmPersistence.savePendingSnoozeIDs(pending, to: defaults)
                    // Last fallback: keep snooze behavior even if config replacement failed.
                    try? AlarmManager.shared.countdown(id: id)
                }
            }
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
            return .result()
        }

        pending.remove(id)
        AlarmPersistence.savePendingSnoozeIDs(pending, to: defaults)
        try AlarmManager.shared.stop(id: id)
        return .result()
    }

    private func makeConfiguration(
        for alarm: UserAlarm,
        schedule: Alarm.Schedule,
        isShadowTrial: Bool
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let showSnoozeButton = alarm.canSnoozeAgain

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
            .init(preAlert: nil, postAlert: snoozeInterval(for: alarm.snoozeDurationMinutes))
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
            stopIntent: nil,
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
