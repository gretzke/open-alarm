import AlarmKit
import Foundation

enum AlarmConfigurationBuilder {

    // MARK: - Primary alarm configuration

    static func makeConfiguration(
        for alarm: AlarmDefinition,
        schedule: Alarm.Schedule,
        defaultSharedSettings: SharedAlarmSettings,
        forceDisableSnooze: Bool = false
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let title = resolvedTitle(for: alarm)
        let sharedSettings = alarm.resolvedSharedSettings(defaults: defaultSharedSettings)
        let showSnooze = !forceDisableSnooze && sharedSettings.canSnoozeAgain(currentCount: alarm.snoozeCount)

        let alertPresentation = AlarmPresentation.Alert(
            title: localizedResource(from: title),
            stopButton: .stopButton,
            secondaryButton: showSnooze ? .snoozeButton : nil,
            secondaryButtonBehavior: showSnooze ? .custom : nil
        )

        let presentation = AlarmPresentation(alert: alertPresentation)

        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: OpenAlarmMetadata(source: alarm.id.uuidString, isShadowTrial: alarm.isTryOut),
            tintColor: OAColor.actionCyan
        )

        let snoozeInterval: TimeInterval = sharedSettings.snoozeDurationMinutes == 0
            ? 5
            : TimeInterval(sharedSettings.snoozeDurationMinutes * 60)

        // Always provide a countdown duration when snooze is configured,
        // even if max snoozes reached — AlarmKit needs it for .fixed schedules
        // to properly transition through countdown → alerting after stop().
        let hasSnoozeConfig = sharedSettings.snoozeEnabled && !forceDisableSnooze
        let countdownDuration: Alarm.CountdownDuration? = hasSnoozeConfig
            ? .init(preAlert: nil, postAlert: snoozeInterval)
            : nil

        return .init(
            countdownDuration: countdownDuration,
            schedule: schedule,
            attributes: attributes,
            stopIntent: StopIntent(alarmID: alarm.id.uuidString),
            secondaryIntent: showSnooze ? SnoozeIntent(alarmID: alarm.id.uuidString) : nil,
            sound: .default
        )
    }

    // MARK: - Bridge alarm configuration

    /// Creates a configuration for a bridge alarm (one-shot override).
    /// Uses the parent alarm's settings but the bridge's own UUID in intent parameters.
    static func makeBridgeConfiguration(
        for parentAlarm: AlarmDefinition,
        bridgeID: UUID,
        schedule: Alarm.Schedule,
        defaultSharedSettings: SharedAlarmSettings
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let title = resolvedTitle(for: parentAlarm)
        let sharedSettings = parentAlarm.resolvedSharedSettings(defaults: defaultSharedSettings)
        let showSnooze = sharedSettings.canSnoozeAgain(currentCount: 0)

        let alertPresentation = AlarmPresentation.Alert(
            title: localizedResource(from: title),
            stopButton: .stopButton,
            secondaryButton: showSnooze ? .snoozeButton : nil,
            secondaryButtonBehavior: showSnooze ? .custom : nil
        )

        let presentation = AlarmPresentation(alert: alertPresentation)

        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: OpenAlarmMetadata(source: parentAlarm.id.uuidString, isShadowTrial: false),
            tintColor: OAColor.actionCyan
        )

        let snoozeInterval: TimeInterval = sharedSettings.snoozeDurationMinutes == 0
            ? 5
            : TimeInterval(sharedSettings.snoozeDurationMinutes * 60)

        let hasSnoozeConfig = sharedSettings.snoozeEnabled
        let countdownDuration: Alarm.CountdownDuration? = hasSnoozeConfig
            ? .init(preAlert: nil, postAlert: snoozeInterval)
            : nil

        return .init(
            countdownDuration: countdownDuration,
            schedule: schedule,
            attributes: attributes,
            stopIntent: StopIntent(alarmID: bridgeID.uuidString),
            secondaryIntent: showSnooze ? SnoozeIntent(alarmID: bridgeID.uuidString) : nil,
            sound: .default
        )
    }

    // MARK: - Wake-check backup alarm configuration

    static func makeWakeCheckBackupConfiguration(
        for alarm: AlarmDefinition,
        deadlineAt: Date
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let title = resolvedTitle(for: alarm)
        let titleResource = localizedResource(from: title)
        let alertPresentation = AlarmPresentation.Alert(
            title: titleResource,
            stopButton: .stopButton,
            secondaryButton: nil,
            secondaryButtonBehavior: nil
        )
        let presentation = AlarmPresentation(alert: alertPresentation)
        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: OpenAlarmMetadata(source: alarm.id.uuidString, isShadowTrial: alarm.isTryOut),
            tintColor: OAColor.actionCyan
        )

        return .init(
            countdownDuration: nil,
            schedule: .fixed(deadlineAt),
            attributes: attributes,
            stopIntent: StopIntent(alarmID: alarm.id.uuidString),
            secondaryIntent: nil,
            sound: .default
        )
    }

    // MARK: - Force-close alarm configuration (anti-circumvention during challenges)

    static func makeForceCloseAlarmConfiguration(
        for alarm: AlarmDefinition,
        fireAt: Date
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let title = resolvedTitle(for: alarm)
        let titleResource = localizedResource(from: title)
        let alertPresentation = AlarmPresentation.Alert(
            title: titleResource,
            stopButton: .stopButton,
            secondaryButton: nil,
            secondaryButtonBehavior: nil
        )
        let presentation = AlarmPresentation(alert: alertPresentation)
        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: OpenAlarmMetadata(source: alarm.id.uuidString, isShadowTrial: alarm.isTryOut),
            tintColor: OAColor.actionCyan
        )

        return .init(
            countdownDuration: nil,
            schedule: .fixed(fireAt),
            attributes: attributes,
            stopIntent: StopIntent(alarmID: alarm.id.uuidString),
            secondaryIntent: nil,
            sound: .default
        )
    }

    // MARK: - Helpers

    static func resolvedTitle(for alarm: AlarmDefinition) -> String {
        if alarm.isNap {
            return String(localized: "nap_default_alarm_label")
        }
        let trimmed = alarm.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return NSLocalizedString("alarm_editor_default_label", comment: "")
        }
        return trimmed
    }

    private static func localizedResource(from text: String) -> LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(text))
    }
}
