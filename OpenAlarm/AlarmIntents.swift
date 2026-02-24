import AlarmKit
import AppIntents
import Foundation

struct SnoozeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Snooze"
    static var description = IntentDescription("Snooze an alarm")

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

            guard alarm.snoozeEnabled else {
                try AlarmManager.shared.stop(id: id)
                return .result()
            }

            if let max = alarm.maxSnoozes, alarm.snoozeCount >= max {
                try AlarmManager.shared.stop(id: id)
                return .result()
            }

            alarm.snoozeCount += 1
            alarm.updatedAt = .now
            alarms[index] = alarm
            AlarmPersistence.saveUserAlarms(alarms, to: defaults)

            try AlarmManager.shared.countdown(id: id)
            return .result()
        }

        var trials = AlarmPersistence.loadShadowTrials(from: defaults)
        if let index = trials.firstIndex(where: { $0.id == id }) {
            var trial = trials[index]

            guard trial.snoozeEnabled else {
                try AlarmManager.shared.stop(id: id)
                try AlarmManager.shared.cancel(id: id)
                trials.remove(at: index)
                AlarmPersistence.saveShadowTrials(trials, to: defaults)
                return .result()
            }

            if let max = trial.maxSnoozes, trial.snoozeCount >= max {
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

            try AlarmManager.shared.countdown(id: id)
            return .result()
        }

        try AlarmManager.shared.countdown(id: id)
        return .result()
    }
}
