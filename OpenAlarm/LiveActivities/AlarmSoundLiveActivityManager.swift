import ActivityKit
import Foundation

@MainActor
final class AlarmSoundLiveActivityManager {
    static let shared = AlarmSoundLiveActivityManager()

    private init() {}

    func start(alarm: AlarmDefinition) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        let title = resolvedTitle(for: alarm)
        let attributes = AlarmSoundLiveActivityAttributes(alarmID: alarm.id.uuidString)
        let content = ActivityContent(
            state: AlarmSoundLiveActivityAttributes.ContentState(alarmName: title),
            staleDate: nil
        )

        Task {
            await endAll()
            do {
                _ = try Activity<AlarmSoundLiveActivityAttributes>.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
            } catch {
                // Live Activity is an enhancement; alarm flow must continue without it.
            }
        }
    }

    func stop() {
        Task {
            await endAll()
        }
    }

    private func endAll() async {
        for activity in Activity<AlarmSoundLiveActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func resolvedTitle(for alarm: AlarmDefinition) -> String {
        let trimmed = alarm.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(localized: "alarm_editor_default_label")
        }
        return trimmed
    }
}
