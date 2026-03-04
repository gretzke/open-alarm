import AlarmKit
import AppIntents
import Foundation
import SwiftUI

/// Centralised alarm configuration builder.
///
/// Previously each call-site (AlarmStore, SnoozeIntent, WakeUpCheckStopIntentArmService)
/// maintained its own copy of title resolution, localized-resource wrapping, snooze-interval
/// calculation, and `AlarmConfiguration` assembly.  This factory unifies them so that changes
/// to presentation or scheduling policy propagate automatically.
enum AlarmConfigurationFactory {

    // MARK: - Public helpers (previously duplicated)

    /// Resolves the user-visible alarm title, falling back to a localised default
    /// when the user-supplied name is blank.
    static func resolvedAlarmTitle(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return NSLocalizedString("alarm_editor_default_label", comment: "")
        }
        return trimmed
    }

    /// Wraps a plain `String` in a `LocalizedStringResource` via
    /// `String.LocalizationValue`.
    static func localizedResource(from text: String) -> LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(text))
    }

    /// Returns the snooze interval in seconds for a given duration-minutes setting.
    /// A zero-minute setting maps to a 5-second interval (used for testing mode).
    static func snoozeInterval(for minutes: Int) -> TimeInterval {
        if minutes == 0 {
            return 5
        }
        return TimeInterval(minutes * 60)
    }

    // MARK: - Configuration builders

    /// Convenience overload that derives title, settings, and snooze state from
    /// a `UserAlarm` plus its default shared settings.
    static func makeConfiguration(
        for alarm: UserAlarm,
        schedule: Alarm.Schedule,
        defaultSharedSettings: SharedAlarmSettings,
        forceDisableSnooze: Bool = false,
        runtimeAlarmID: UUID? = nil,
        configReferenceID: UUID? = nil
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let sharedSettings = alarm.resolvedSharedSettings(defaults: defaultSharedSettings)
        let title = alarm.isNap
            ? String(localized: "nap_default_alarm_label")
            : resolvedAlarmTitle(from: alarm.name)

        return makeConfiguration(
            runtimeAlarmID: runtimeAlarmID ?? alarm.id,
            configReferenceID: configReferenceID ?? alarm.scheduleConfigReferenceID,
            title: title,
            schedule: schedule,
            sharedSettings: sharedSettings,
            snoozeCount: alarm.snoozeCount,
            isShadowTrial: alarm.isTryOut,
            forceDisableSnooze: forceDisableSnooze
        )
    }

    /// Low-level configuration builder with fully-explicit parameters.
    static func makeConfiguration(
        runtimeAlarmID: UUID,
        configReferenceID: UUID,
        title: String,
        schedule: Alarm.Schedule,
        sharedSettings: SharedAlarmSettings,
        snoozeCount: Int,
        isShadowTrial: Bool,
        forceDisableSnooze: Bool
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let showSnoozeButton = !forceDisableSnooze && sharedSettings.canSnoozeAgain(currentCount: snoozeCount)

        let alertPresentation = AlarmPresentation.Alert(
            title: localizedResource(from: title),
            stopButton: .stopButton,
            secondaryButton: showSnoozeButton ? .snoozeButton : nil,
            secondaryButtonBehavior: showSnoozeButton ? .custom : nil
        )

        let presentation = AlarmPresentation(alert: alertPresentation)

        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: OpenAlarmMetadata(source: configReferenceID.uuidString, isShadowTrial: isShadowTrial),
            tintColor: OAColor.actionCyan
        )

        let secondaryIntent: (any LiveActivityIntent)? = if showSnoozeButton {
            SnoozeIntent(alarmID: runtimeAlarmID.uuidString)
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
            stopIntent: StopIntent(alarmID: runtimeAlarmID.uuidString),
            secondaryIntent: secondaryIntent,
            sound: .default
        )
    }

    /// Builds a wake-check-specific configuration (no snooze affordance).
    static func wakeCheckConfiguration(
        for alarm: UserAlarm,
        deadlineAt: Date
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        makeConfiguration(
            runtimeAlarmID: alarm.id,
            configReferenceID: alarm.scheduleConfigReferenceID,
            title: alarm.isNap
                ? String(localized: "nap_default_alarm_label")
                : resolvedAlarmTitle(from: alarm.name),
            schedule: .fixed(deadlineAt),
            sharedSettings: SharedAlarmSettings.featureDefaults, // placeholder — snooze forced off below
            snoozeCount: 0,
            isShadowTrial: alarm.isTryOut,
            forceDisableSnooze: true
        )
    }
}
