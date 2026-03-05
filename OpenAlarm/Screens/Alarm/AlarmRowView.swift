import SwiftUI

struct AlarmRowView: View {
    let alarm: UserAlarm
    let now: Date
    let disableChoicePopoverPresented: Bool
    let onDisableChoicePopoverPresentedChange: (Bool) -> Void
    let onSkipNextSelected: () -> Void
    let onDisableCompletelySelected: () -> Void
    let onToggle: (Bool) -> Void

    private var localeOrderedWeekdays: [AlarmWeekday] {
        AlarmWeekday.orderedForCurrentLocale()
    }

    private var calendar: Calendar {
        .autoupdatingCurrent
    }

    private var resolvedName: String {
        let trimmed = alarm.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(localized: "alarm_editor_default_label")
        }
        return trimmed
    }

    private var baseScheduledDate: Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = alarm.hour
        components.minute = alarm.minute
        components.second = 0
        return calendar.date(from: components) ?? now
    }

    private var showsOverrideTime: Bool {
        guard alarm.isRepeating,
              alarm.isEnabled,
              let overrideDate = alarm.nextTriggerOverrideDate else {
            return false
        }

        let overrideComponents = calendar.dateComponents([.hour, .minute], from: overrideDate)
        return overrideComponents.hour != alarm.hour || overrideComponents.minute != alarm.minute
    }

    private var nextRunText: String? {
        guard let nextRunDate else {
            return nil
        }

        let delta = nextRunDate.timeIntervalSince(now)
        if delta > 0, delta < 12 * 60 * 60 {
            return countdownText(until: nextRunDate)
        }

        if calendar.isDateInToday(nextRunDate) {
            return String(localized: "alarm_row_next_run_today")
        }

        if calendar.isDateInTomorrow(nextRunDate) {
            return String(localized: "alarm_row_next_run_tomorrow")
        }

        return nextRunDate.formatted(.dateTime.weekday(.wide))
    }

    private var nextRunDate: Date? {
        guard !alarm.isFullyDisabled else {
            return nil
        }

        if alarm.isRepeating {
            if alarm.isSkippingNext, let skipUntil = alarm.skipNextUntilDate {
                return nextRepeatingDate(after: skipUntil)
            }

            if let overrideDate = alarm.nextTriggerOverrideDate, overrideDate > now {
                return overrideDate
            }

            return nextRepeatingDate(after: now)
        }

        if let overrideDate = alarm.nextTriggerOverrideDate, overrideDate > now {
            return overrideDate
        }

        return nextOneTimeDate(after: now)
    }

    private var hasRepeatingDays: Bool {
        alarm.isRepeating && !alarm.repeatDays.isEmpty
    }

    private var repeatDayStrip: some View {
        let activeDays = Set(alarm.repeatDays)

        return HStack(spacing: 6) {
            ForEach(localeOrderedWeekdays) { day in
                Text(day.veryShortSymbol())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(activeDays.contains(day) ? OAColor.textPrimary : OAColor.textSecondary.opacity(0.65))
                    .frame(minWidth: 12)
            }
        }
    }

    private func countdownText(until nextRunDate: Date) -> String {
        let totalMinutes = max(1, Int(ceil(nextRunDate.timeIntervalSince(now) / 60)))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        return String(
            format: String(localized: "alarm_row_countdown_hours_minutes"),
            hours,
            minutes
        )
    }

    private func popoverActionButton(title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OAColor.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(GlassButtonStyle())
    }

    private func nextRepeatingDate(after referenceDate: Date) -> Date? {
        let searchStart = referenceDate.addingTimeInterval(1)

        let candidates = alarm.sortedRepeatDays.compactMap { weekday -> Date? in
            var components = DateComponents()
            components.weekday = weekday.rawValue
            components.hour = alarm.hour
            components.minute = alarm.minute
            components.second = 0

            return calendar.nextDate(
                after: searchStart,
                matching: components,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            )
        }

        return candidates.min()
    }

    private func nextOneTimeDate(after referenceDate: Date) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        components.hour = alarm.hour
        components.minute = alarm.minute
        components.second = 0

        guard let candidate = calendar.date(from: components) else {
            return nil
        }

        if candidate > referenceDate {
            return candidate
        }

        return calendar.date(byAdding: .day, value: 1, to: candidate)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            alarmTimeSection
            statusStrip
        }
        .padding(18)
        .oaGlassCard()
        .padding(.vertical, 6)
    }

    private var alarmTimeSection: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(resolvedName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(OAColor.textPrimary)

                if showsOverrideTime, let overrideDate = alarm.nextTriggerOverrideDate {
                    Text(overrideDate, style: .time)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(OAColor.textPrimary)

                    HStack(spacing: 4) {
                        Text(L10n.alarmRowUsualTimePrefix)
                            .font(.caption)
                            .foregroundStyle(OAColor.textSecondary)

                        Text(baseScheduledDate, style: .time)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(OAColor.textSecondary)
                    }
                } else {
                    Text(baseScheduledDate, style: .time)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(OAColor.textPrimary)
                }
            }

            Spacer(minLength: 0)

            toggleWithPopover
        }
    }

    private var toggleWithPopover: some View {
        Toggle(isOn: Binding(
            get: { alarm.isEnabled },
            set: { onToggle($0) }
        )) {
            EmptyView()
        }
        .labelsHidden()
        .tint(OAColor.actionCyan)
        .popover(
            isPresented: Binding(
                get: { disableChoicePopoverPresented },
                set: { onDisableChoicePopoverPresentedChange($0) }
            ),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            GlassEffectContainer(spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    popoverActionButton(
                        title: L10n.alarmRowSkipNextYes,
                        action: onSkipNextSelected
                    )

                    popoverActionButton(
                        title: L10n.alarmRowSkipNextNo,
                        action: onDisableCompletelySelected
                    )
                }
            }
            .padding(14)
            .frame(width: 252, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private var statusStrip: some View {
        if alarm.isSkippingNext || nextRunText != nil || hasRepeatingDays {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if alarm.isSkippingNext {
                    Text(L10n.alarmRowSkippingNextStatus)
                        .font(.caption)
                        .foregroundStyle(OAColor.textSecondary)
                } else if let nextRunText {
                    HStack(spacing: 6) {
                        Text(L10n.alarmRowNextRunPrefix)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(OAColor.textSecondary)

                        Text(nextRunText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(OAColor.textPrimary)
                    }
                }

                Spacer(minLength: 0)

                if hasRepeatingDays {
                    repeatDayStrip
                }
            }
        }
    }
}
