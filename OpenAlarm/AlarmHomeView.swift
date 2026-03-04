import SwiftUI

struct AlarmHomeView: View {
    @EnvironmentObject private var alarmStore: AlarmStore
    @State private var editorRoute: AlarmEditorRoute?
    @State private var editorDetent: PresentationDetent = .fraction(0.82)
    @State private var isPresentingNapEditor = false
    @State private var pendingDisableConfirmationAlarm: UserAlarm?
    @State private var now = Date.now

    private let editorPartialDetent: PresentationDetent = .fraction(0.82)
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private func presentEditor(_ route: AlarmEditorRoute) {
        editorDetent = editorPartialDetent
        editorRoute = route
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let nap = alarmStore.activeNap {
                        ActiveNapRowView(
                            nap: nap,
                            now: now,
                            onPause: {
                                alarmStore.pauseNap()
                            },
                            onContinue: {
                                Task {
                                    await alarmStore.resumeNap()
                                }
                            },
                            onDelete: {
                                alarmStore.deleteNap()
                            }
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    } else {
                        NapBannerView {
                            isPresentingNapEditor = true
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }

                Section {
                    HStack(alignment: .center) {
                        Text(L10n.alarmListTitle)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(OAColor.textPrimary)

                        Spacer(minLength: 0)

                        Button {
                            presentEditor(.create)
                        } label: {
                            Image(systemName: "plus")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(OAColor.actionCyan)
                                .frame(width: 40, height: 40)
                                .glassEffect(.regular.interactive(), in: Circle())
                                .overlay(
                                    Circle()
                                        .stroke(OAColor.glassStroke.opacity(0.85), lineWidth: 0.9)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("alarm_add_button")
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                if alarmStore.regularAlarms.isEmpty {
                    Section {
                        ContentUnavailableView(
                            L10n.alarmListEmptyTitle,
                            systemImage: "alarm",
                            description: Text(L10n.alarmListEmptySubtitle)
                        )
                        .foregroundStyle(OAColor.textSecondary)
                        .padding(.vertical, 24)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(alarmStore.regularAlarms) { alarm in
                            AlarmRowView(
                                alarm: alarm,
                                now: now,
                                disableChoicePopoverPresented: pendingDisableConfirmationAlarm?.id == alarm.id,
                                onDisableChoicePopoverPresentedChange: { isPresented in
                                    if !isPresented, pendingDisableConfirmationAlarm?.id == alarm.id {
                                        pendingDisableConfirmationAlarm = nil
                                    }
                                },
                                onSkipNextSelected: {
                                    setAlarmEnabled(alarm, isOn: false, skipNext: true)
                                    pendingDisableConfirmationAlarm = nil
                                },
                                onDisableCompletelySelected: {
                                    setAlarmEnabled(alarm, isOn: false, skipNext: false)
                                    pendingDisableConfirmationAlarm = nil
                                },
                                onToggle: { isOn in
                                    handleAlarmToggle(alarm, isOn: isOn)
                                }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                presentEditor(.edit(alarm))
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    alarmStore.deleteAlarm(alarm)
                                } label: {
                                    Label(L10n.actionDelete, systemImage: "trash")
                                }
                                .tint(OAColor.danger)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OAColor.background.ignoresSafeArea())
            .onAppear {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("uitestOpenCreateAlarm") {
                    presentEditor(.create)
                }
#endif
            }
            .onReceive(timer) { tick in
                now = tick
            }
        }
        .sheet(item: $editorRoute) { route in
            AlarmEditorView(route: route)
                .environmentObject(alarmStore)
                .presentationDetents([editorPartialDetent, .large], selection: $editorDetent)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isPresentingNapEditor) {
            NapEditorView(
                initialDraft: NapDraft(
                    totalMinutes: alarmStore.defaultNapDurationMinutes,
                    customSharedSettings: alarmStore.defaultSharedSettings
                )
            )
            .environmentObject(alarmStore)
            .presentationDetents([.fraction(0.4), .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func handleAlarmToggle(_ alarm: UserAlarm, isOn: Bool) {
        if !isOn, alarm.isRepeating, alarm.isEnabled {
            pendingDisableConfirmationAlarm = alarm
            return
        }

        setAlarmEnabled(alarm, isOn: isOn, skipNext: nil)
    }

    private func setAlarmEnabled(_ alarm: UserAlarm, isOn: Bool, skipNext: Bool?) {
        Task {
            try? await alarmStore.setAlarmEnabled(alarm, enabled: isOn, skipNext: skipNext)
        }
    }
}

// MARK: - Supporting Views

private struct NapBannerView: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: Circle())
                        .overlay(
                            Circle()
                                .stroke(OAColor.glassStroke.opacity(0.75), lineWidth: 0.8)
                        )

                    Image(systemName: "zzz")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(OAColor.actionCyan)
                }

                Text(L10n.napBannerTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(OAColor.textPrimary)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(OAColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .oaGlassCard()
            .contentShape(RoundedRectangle(cornerRadius: OARadius.card, style: .continuous))
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nap_banner_take_nap")
    }
}

private struct ActiveNapRowView: View {
    let nap: UserAlarm
    let now: Date
    let onPause: () -> Void
    let onContinue: () -> Void
    let onDelete: () -> Void

    private var remainingTimeString: String {
        let remaining = Int(nap.remainingSeconds(referenceDate: now))
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.napActiveTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(OAColor.textPrimary)

                Spacer(minLength: 0)
            }

            Text(remainingTimeString)
                .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(OAColor.textPrimary)

            HStack(spacing: 10) {
                Button {
                    if nap.isPaused {
                        onContinue()
                    } else {
                        onPause()
                    }
                } label: {
                    Label(nap.isPaused ? L10n.actionContinue : L10n.actionPause, systemImage: nap.isPaused ? "play.fill" : "pause.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(OAColor.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GlassButtonStyle())

                Button(action: onDelete) {
                    Label(L10n.actionDelete, systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(OAColor.danger)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(18)
        .oaGlassCard()
        .padding(.vertical, 6)
    }
}

private struct AlarmRowView: View {
    let alarm: UserAlarm
    let now: Date
    let disableChoicePopoverPresented: Bool
    let onDisableChoicePopoverPresentedChange: (Bool) -> Void
    let onSkipNextSelected: () -> Void
    let onDisableCompletelySelected: () -> Void
    let onToggle: (Bool) -> Void

    private let mondayFirstWeekdays: [(AlarmWeekday, String)] = [
        (.monday, "M"),
        (.tuesday, "T"),
        (.wednesday, "W"),
        (.thursday, "T"),
        (.friday, "F"),
        (.saturday, "S"),
        (.sunday, "S")
    ]

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
            ForEach(mondayFirstWeekdays, id: \.0) { day, symbol in
                Text(symbol)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        .padding(18)
        .oaGlassCard()
        .padding(.vertical, 6)
    }
}
