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

    func perform() throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else {
            return .result()
        }

        let defaults = UserDefaults.standard

        var alarms = AlarmPersistence.loadUserAlarms(from: defaults)
        if let index = alarms.firstIndex(where: { $0.id == id }) {
            var alarm = alarms[index]

            guard alarm.canSnoozeAgain else {
                try AlarmManager.shared.stop(id: id)
                return .result()
            }

            alarm.snoozeCount += 1
            alarm.updatedAt = .now
            alarms[index] = alarm
            AlarmPersistence.saveUserAlarms(alarms, to: defaults)

            let snoozeDate = Date.now.addingTimeInterval(TimeInterval(alarm.snoozeDurationMinutes * 60))
            try AlarmManager.shared.countdown(id: id)

            let snapshot = alarm
            Task {
                do {
                    let config = makeConfiguration(for: snapshot, schedule: .fixed(snoozeDate), isShadowTrial: false)
                    _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
                } catch {
                    // Keep countdown behavior even if override schedule fails.
                }
            }
            return .result()
        }

        var trials = AlarmPersistence.loadShadowTrials(from: defaults)
        if let index = trials.firstIndex(where: { $0.id == id }) {
            var trial = trials[index]

            guard trial.canSnoozeAgain else {
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

            let snoozeDate = Date.now.addingTimeInterval(TimeInterval(trial.snoozeDurationMinutes * 60))
            try AlarmManager.shared.countdown(id: id)

            let snapshot = trial
            Task {
                do {
                    let config = makeConfiguration(for: snapshot, schedule: .fixed(snoozeDate))
                    _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
                } catch {
                    // Keep countdown behavior even if override schedule fails.
                }
            }
            return .result()
        }

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
            title: LocalizedStringResource("app_title"),
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
            .init(preAlert: nil, postAlert: TimeInterval(alarm.snoozeDurationMinutes * 60))
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
            title: LocalizedStringResource("app_title"),
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
            .init(preAlert: nil, postAlert: TimeInterval(trial.snoozeDurationMinutes * 60))
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
}
