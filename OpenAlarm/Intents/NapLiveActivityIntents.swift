import ActivityKit
import AlarmKit
import AppIntents
import Foundation

struct NapExtendIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "nap_live_activity_extend_title"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "napID")
    var napID: String

    @Parameter(title: "minutes")
    var minutes: Int

    init(napID: String, minutes: Int) {
        self.napID = napID
        self.minutes = minutes
    }

    init() {
        self.napID = ""
        self.minutes = 0
    }

    func perform() async throws -> some IntentResult {
        guard minutes > 0,
              let id = UUID(uuidString: napID) else {
            return .result()
        }

        let persistence = AlarmPersistence(defaults: OpenAlarmSharedDefaults.userDefaults)
        var alarms = persistence.loadUserAlarms()
        guard let index = alarms.firstIndex(where: { $0.id == id && $0.isNap }) else {
            await MainActor.run {
                NapCountdownLiveActivityManager.shared.stop()
            }
            return .result()
        }

        var nap = alarms[index]
        let addedSeconds = TimeInterval(minutes * 60)
        nap.durationMinutes = max(0, (nap.durationMinutes ?? 0) + minutes)
        nap.updatedAt = .now

        if let pausedRemaining = nap.pausedRemainingSeconds {
            nap.pausedRemainingSeconds = pausedRemaining + addedSeconds
            alarms[index] = nap
            persistence.saveUserAlarms(alarms)
            let updatedNap = nap
            await MainActor.run {
                NapCountdownLiveActivityManager.shared.sync(with: updatedNap)
            }
            return .result()
        }

        let updatedTarget = (nap.fixedTriggerDate ?? .now).addingTimeInterval(addedSeconds)
        nap.fixedTriggerDate = updatedTarget
        nap.isEnabled = true
        nap.lifecycleState = .scheduled
        alarms[index] = nap
        persistence.saveUserAlarms(alarms)

        let defaultSharedSettings = persistence.loadDefaultSharedSettings()
        let effectiveDefaults = persistence.loadNapDefaultSharedSettings() ?? defaultSharedSettings
        let config = AlarmConfigurationBuilder.makeConfiguration(
            for: nap,
            schedule: .fixed(updatedTarget),
            defaultSharedSettings: effectiveDefaults
        )

        try? AlarmManager.shared.stop(id: id)
        try? AlarmManager.shared.cancel(id: id)
        _ = try? await AlarmManager.shared.schedule(id: id, configuration: config)

        let updatedNap = nap
        await MainActor.run {
            NapCountdownLiveActivityManager.shared.sync(with: updatedNap)
        }

        return .result()
    }
}

struct NapPauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "action_pause"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "napID")
    var napID: String

    init(napID: String) {
        self.napID = napID
    }

    init() {
        self.napID = ""
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: napID) else {
            return .result()
        }

        let persistence = AlarmPersistence(defaults: OpenAlarmSharedDefaults.userDefaults)
        var alarms = persistence.loadUserAlarms()
        guard let index = alarms.firstIndex(where: { $0.id == id && $0.isNap }) else {
            await MainActor.run {
                NapCountdownLiveActivityManager.shared.stop()
            }
            return .result()
        }

        var nap = alarms[index]
        guard !nap.isPaused else {
            let updatedNap = nap
            await MainActor.run {
                NapCountdownLiveActivityManager.shared.sync(with: updatedNap)
            }
            return .result()
        }

        nap.pausedRemainingSeconds = nap.remainingSeconds(referenceDate: .now)
        nap.isEnabled = false
        nap.updatedAt = .now
        alarms[index] = nap
        persistence.saveUserAlarms(alarms)

        try? AlarmManager.shared.stop(id: id)
        try? AlarmManager.shared.cancel(id: id)

        let updatedNap = nap
        await MainActor.run {
            NapCountdownLiveActivityManager.shared.sync(with: updatedNap)
        }

        return .result()
    }
}

struct NapResumeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "action_continue"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "napID")
    var napID: String

    init(napID: String) {
        self.napID = napID
    }

    init() {
        self.napID = ""
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: napID) else {
            return .result()
        }

        let persistence = AlarmPersistence(defaults: OpenAlarmSharedDefaults.userDefaults)
        var alarms = persistence.loadUserAlarms()
        guard let index = alarms.firstIndex(where: { $0.id == id && $0.isNap }) else {
            await MainActor.run {
                NapCountdownLiveActivityManager.shared.stop()
            }
            return .result()
        }

        var nap = alarms[index]
        guard let remaining = nap.pausedRemainingSeconds else {
            let updatedNap = nap
            await MainActor.run {
                NapCountdownLiveActivityManager.shared.sync(with: updatedNap)
            }
            return .result()
        }

        let newTarget = Date.now.addingTimeInterval(remaining)
        nap.fixedTriggerDate = newTarget
        nap.pausedRemainingSeconds = nil
        nap.isEnabled = true
        nap.lifecycleState = .scheduled
        nap.updatedAt = .now
        alarms[index] = nap
        persistence.saveUserAlarms(alarms)

        let defaultSharedSettings = persistence.loadDefaultSharedSettings()
        let effectiveDefaults = persistence.loadNapDefaultSharedSettings() ?? defaultSharedSettings
        let config = AlarmConfigurationBuilder.makeConfiguration(
            for: nap,
            schedule: .fixed(newTarget),
            defaultSharedSettings: effectiveDefaults
        )

        try? AlarmManager.shared.stop(id: id)
        try? AlarmManager.shared.cancel(id: id)
        _ = try? await AlarmManager.shared.schedule(id: id, configuration: config)

        let updatedNap = nap
        await MainActor.run {
            NapCountdownLiveActivityManager.shared.sync(with: updatedNap)
        }

        return .result()
    }
}

struct NapDeleteIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "action_delete"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "napID")
    var napID: String

    init(napID: String) {
        self.napID = napID
    }

    init() {
        self.napID = ""
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: napID) else {
            return .result()
        }

        let persistence = AlarmPersistence(defaults: OpenAlarmSharedDefaults.userDefaults)
        var alarms = persistence.loadUserAlarms()
        guard alarms.contains(where: { $0.id == id && $0.isNap }) else {
            await MainActor.run {
                NapCountdownLiveActivityManager.shared.stop()
            }
            return .result()
        }

        alarms.removeAll { $0.id == id }
        persistence.saveUserAlarms(alarms)

        try? AlarmManager.shared.stop(id: id)
        try? AlarmManager.shared.cancel(id: id)

        await MainActor.run {
            NapCountdownLiveActivityManager.shared.stop()
        }

        return .result()
    }
}
