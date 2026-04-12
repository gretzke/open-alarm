import ActivityKit
import Foundation

@MainActor
final class NapCountdownLiveActivityManager {
    static let shared = NapCountdownLiveActivityManager()

    private init() {}

    func sync(with nap: AlarmDefinition?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              AlarmPersistence(defaults: OpenAlarmSharedDefaults.userDefaults).loadLiveActivitiesEnabled() else {
            Task { await endAll() }
            return
        }

        guard let nap, nap.isNap else {
            Task { await endAll() }
            return
        }

        let remainingSeconds = Int(ceil(nap.remainingSeconds(referenceDate: .now)))
        guard remainingSeconds > 0 else {
            Task { await endAll() }
            return
        }

        let endDate = nap.isPaused ? nil : nap.fixedTriggerDate
        guard nap.isPaused || (nap.isEnabled && endDate != nil) else {
            Task { await endAll() }
            return
        }

        let attributes = NapCountdownLiveActivityAttributes(napID: nap.id.uuidString)
        let content = ActivityContent(
            state: NapCountdownLiveActivityAttributes.ContentState(
                endDate: endDate,
                pausedRemainingSeconds: nap.isPaused ? remainingSeconds : nil,
                isSnoozing: nap.snoozeCount > 0,
                isPaused: nap.isPaused
            ),
            staleDate: endDate
        )

        Task {
            await upsert(attributes: attributes, content: content)
        }
    }

    func stop() {
        Task {
            await endAll()
        }
    }

    private func upsert(
        attributes: NapCountdownLiveActivityAttributes,
        content: ActivityContent<NapCountdownLiveActivityAttributes.ContentState>
    ) async {
        let activities = Activity<NapCountdownLiveActivityAttributes>.activities

        for activity in activities where activity.attributes.napID != attributes.napID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        if let current = activities.first(where: { $0.attributes.napID == attributes.napID }) {
            await current.update(content)
            return
        }

        do {
            _ = try Activity<NapCountdownLiveActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            // Live Activity is optional. Nap scheduling must continue without it.
        }
    }

    private func endAll() async {
        for activity in Activity<NapCountdownLiveActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
