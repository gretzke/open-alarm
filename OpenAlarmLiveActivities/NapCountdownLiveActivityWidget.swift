import ActivityKit
import AppIntents
import Foundation
import SwiftUI
import UIKit
import WidgetKit

private let openAlarmNapURL = URL(string: "openalarm://nap")!
private let napLiveActivityAccent = Color.cyan

struct NapCountdownLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NapCountdownLiveActivityAttributes.self) { context in
            NapCountdownExpandedContent(context: context, showsButtons: true)
                .widgetURL(openAlarmNapURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    NapCountdownExpandedContent(context: context, showsButtons: true)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: "zzz")
                    .foregroundStyle(napLiveActivityAccent)
            } compactTrailing: {
                NapCompactCountdownText(state: context.state)
            } minimal: {
                Image(systemName: "zzz")
                    .foregroundStyle(napLiveActivityAccent)
            }
            .widgetURL(openAlarmNapURL)
            .keylineTint(napLiveActivityAccent)
        }
    }
}

private struct NapCountdownExpandedContent: View {
    let context: ActivityViewContext<NapCountdownLiveActivityAttributes>
    let showsButtons: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                NapCountdownGlyph()

                VStack(alignment: .leading, spacing: 3) {
                    Text(titleKey)
                        .font(.headline)
                        .lineLimit(1)

                    subtitleView
                }

                Spacer(minLength: 0)

                NapPrimaryTimeText(state: context.state)
            }

            if showsButtons {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        if context.state.isPaused {
                            NapIconActionButton(
                                accessibilityLabel: "action_continue",
                                systemImage: "play.fill",
                                tint: napLiveActivityAccent,
                                intent: NapResumeIntent(napID: context.attributes.napID)
                            )
                        } else {
                            NapIconActionButton(
                                accessibilityLabel: "action_pause",
                                systemImage: "pause.fill",
                                tint: napLiveActivityAccent,
                                intent: NapPauseIntent(napID: context.attributes.napID)
                            )
                        }

                        NapIconActionButton(
                            accessibilityLabel: "action_delete",
                            systemImage: "xmark",
                            tint: .red,
                            intent: NapDeleteIntent(napID: context.attributes.napID)
                        )
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        NapExtendButton(
                            title: "+1",
                            minutes: 1,
                            napID: context.attributes.napID,
                            accessibilityLabel: "nap_active_add_one_minute"
                        )

                        NapExtendButton(
                            title: "+5",
                            minutes: 5,
                            napID: context.attributes.napID,
                            accessibilityLabel: "nap_active_add_five_minutes"
                        )

                        NapExtendButton(
                            title: "+10",
                            minutes: 10,
                            napID: context.attributes.napID,
                            accessibilityLabel: "nap_active_add_ten_minutes"
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct NapExtendButton: View {
    let title: String
    let minutes: Int
    let napID: String
    let accessibilityLabel: LocalizedStringKey

    var body: some View {
        Button(intent: NapExtendIntent(napID: napID, minutes: minutes)) {
            Text(title)
                .font(.footnote.weight(.bold))
                .foregroundStyle(napLiveActivityAccent)
                .padding(.horizontal, 12)
                .frame(minWidth: 48, minHeight: 34)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(napLiveActivityAccent.opacity(0.14))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct NapIconActionButton<Intent: AppIntent>: View {
    let accessibilityLabel: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let intent: Intent

    var body: some View {
        Button(intent: intent) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.14))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct NapCompactCountdownText: View {
    let state: NapCountdownLiveActivityAttributes.ContentState

    private let compactTimerFont = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    var body: some View {
        Group {
            if let endDate = state.endDate {
                TextTimer(endDate, font: compactTimerFont)
            } else {
                Text(formattedDuration(state.pausedRemainingSeconds ?? 0))
            }
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .foregroundStyle(napLiveActivityAccent)
        .lineLimit(1)
    }
}

private struct TextTimer: View {
    let date: Date
    let font: UIFont
    let width: CGFloat

    init(_ date: Date, font: UIFont, width: CGFloat? = nil) {
        self.date = date
        self.font = font

        if let width {
            self.width = width
        } else {
            let fontAttributes = [NSAttributedString.Key.font: font]
            let maxString = Self.maxString(for: date.timeIntervalSinceNow)
            self.width = (maxString as NSString).size(withAttributes: fontAttributes).width
        }
    }

    var body: some View {
        Text(timerInterval: Date.now...date)
            .font(Font(font))
            .frame(width: width > 0 ? width : nil)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
    }

    private static func maxString(for time: TimeInterval) -> String {
        if time < 600 {
            return "0:00"
        }
        if time < 3600 {
            return "00:00"
        }
        if time < 36000 {
            return "0:00:00"
        }
        return "00:00:00"
    }
}

private struct NapPrimaryTimeText: View {
    let state: NapCountdownLiveActivityAttributes.ContentState

    var body: some View {
        Group {
            if let endDate = state.endDate {
                Text(endDate, style: .timer)
            } else {
                Text(formattedDuration(state.pausedRemainingSeconds ?? 0))
            }
        }
        .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
        .foregroundStyle(.primary)
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

private struct NapCountdownGlyph: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(napLiveActivityAccent.opacity(0.18))

            Image(systemName: "zzz")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(napLiveActivityAccent)
        }
        .frame(width: 42, height: 42)
    }
}

private extension NapCountdownExpandedContent {
    var titleKey: LocalizedStringKey {
        if context.state.isPaused {
            return "nap_active_paused"
        }
        if context.state.isSnoozing {
            return "nap_active_snoozing_title"
        }
        return "nap_active_title"
    }

    @ViewBuilder
    var subtitleView: some View {
        if let endDate = context.state.endDate {
            Text(endDate, style: .time)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if !context.state.isPaused {
            Text("action_continue")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private func formattedDuration(_ totalSeconds: Int) -> String {
    let remaining = max(0, totalSeconds)
    let hours = remaining / 3600
    let minutes = (remaining % 3600) / 60
    let seconds = remaining % 60

    if hours > 0 {
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    return String(format: "%02d:%02d", minutes, seconds)
}
