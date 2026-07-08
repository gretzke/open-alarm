import ActivityKit
import SwiftUI
import WidgetKit

private let openAlarmLiveActivityURL = URL(string: "openalarm://alarm")!
/// Mirror of OAColor.actionCyan (OpenAlarm/Theme/OpenAlarmTheme.swift) — the
/// widget target doesn't compile the theme file; keep in sync.
private let liveActivityAccent = Color(red: 100 / 255, green: 210 / 255, blue: 255 / 255)

@main
struct OpenAlarmLiveActivitiesBundle: WidgetBundle {
    var body: some Widget {
        AlarmSoundLiveActivityWidget()
        NapCountdownLiveActivityWidget()
    }
}

struct AlarmSoundLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmSoundLiveActivityAttributes.self) { context in
            AlarmSoundExpandedContent(context: context)
                .widgetURL(openAlarmLiveActivityURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    AlarmSoundExpandedContent(context: context)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: "alarm.fill")
                    .foregroundStyle(liveActivityAccent)
            } compactTrailing: {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(liveActivityAccent)
            } minimal: {
                Image(systemName: "alarm.fill")
                    .foregroundStyle(liveActivityAccent)
            }
            .widgetURL(openAlarmLiveActivityURL)
            .keylineTint(liveActivityAccent)
        }
    }
}

private struct AlarmSoundExpandedContent: View {
    let context: ActivityViewContext<AlarmSoundLiveActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            AlarmSoundGlyph(systemName: "alarm.fill", diameter: 42, iconSize: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text("live_activity_alarm_ringing_title")
                    .font(.headline)
                    .lineLimit(1)

                Text(context.state.alarmName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("live_activity_alarm_ringing_return_hint")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            AlarmSoundGlyph(systemName: "speaker.wave.2.fill", diameter: 42, iconSize: 20)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct AlarmSoundGlyph: View {
    let systemName: String
    let diameter: CGFloat
    let iconSize: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(liveActivityAccent.opacity(0.18))

            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(liveActivityAccent)
        }
        .frame(width: diameter, height: diameter)
    }
}
