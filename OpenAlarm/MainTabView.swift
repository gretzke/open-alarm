import SwiftUI

private enum MainTab: Hashable {
    case alarm
    case settings
}

struct MainTabView: View {
    @State private var selectedTab: MainTab = .alarm

    var body: some View {
        TabView(selection: $selectedTab) {
            AlarmHomeView()
                .tag(MainTab.alarm)
                .tabItem {
                    Label {
                        Text(L10n.tabAlarm)
                    } icon: {
                        Image(systemName: "alarm.fill")
                    }
                }

            SettingsHomeView()
                .tag(MainTab.settings)
                .tabItem {
                    Label {
                        Text(L10n.tabSettings)
                    } icon: {
                        Image(systemName: "gearshape.fill")
                    }
                }
        }
        .tint(OAColor.actionCyan)
        .background(OAColor.background.ignoresSafeArea())
    }
}

private struct AlarmHomeView: View {
    @EnvironmentObject private var alarmStore: AlarmStore
    @State private var editorRoute: AlarmEditorRoute?
    @State private var editorDetent: PresentationDetent = .fraction(0.82)
    @State private var isPresentingNapEditor = false
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
                    Text(L10n.alarmListTitle)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(OAColor.textPrimary)
                        .padding(.horizontal, 4)
                        .padding(.top, 6)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                if alarmStore.alarms.isEmpty {
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
                        ForEach(alarmStore.alarms) { alarm in
                            AlarmRowView(
                                alarm: alarm,
                                lifecycleText: alarmStore.lifecycleLabel(for: alarm.lifecycleState)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presentEditor(.create)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(OAColor.actionCyan)
                    .accessibilityIdentifier("alarm_add_button")
                }
            }
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
            .presentationDetents([.fraction(0.7), .large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct NapBannerView: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(OAColor.glassFill)
                        .frame(width: 44, height: 44)

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
            .padding(18)
            .oaGlassCard()
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

private struct ActiveNapRowView: View {
    let nap: NapAlarmSession
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
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(OAColor.background)
                        .background(
                            RoundedRectangle(cornerRadius: OARadius.button, style: .continuous)
                                .fill(OAColor.actionCyan)
                        )
                }
                .buttonStyle(.plain)

                Button(role: .destructive, action: onDelete) {
                    Label(L10n.actionDelete, systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(OAColor.textPrimary)
                        .background(
                            RoundedRectangle(cornerRadius: OARadius.button, style: .continuous)
                                .fill(OAColor.glassFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: OARadius.button, style: .continuous)
                                .stroke(OAColor.danger.opacity(0.75), lineWidth: 0.9)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .oaGlassCard()
        .padding(.vertical, 6)
    }
}

private struct AlarmRowView: View {
    let alarm: UserAlarm
    let lifecycleText: LocalizedStringKey

    private var repeatDescription: String {
        if alarm.repeatDays.isEmpty {
            return String(localized: "alarm_row_repeat_one_time")
        }

        return "\(String(localized: "alarm_row_repeat_prefix")): \(alarm.sortedRepeatDays.repeatSummary())"
    }

    private var resolvedName: String {
        let trimmed = alarm.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(localized: "alarm_editor_default_label")
        }
        return trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(alarm.triggerDateForDisplay, style: .time)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(OAColor.textPrimary)

                Spacer(minLength: 0)

                Text(lifecycleText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(OAColor.background)
                    .background(
                        Capsule(style: .continuous)
                            .fill(OAColor.actionCyan)
                    )
            }

            Text(resolvedName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(OAColor.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text(repeatDescription)
                    .font(.subheadline)
                    .foregroundStyle(OAColor.textSecondary)

                Text(alarm.deleteAfterUse ? L10n.alarmRowDeleteAfterUse : L10n.alarmRowKeepAfterUse)
                    .font(.caption)
                    .foregroundStyle(OAColor.textSecondary)
            }
        }
        .padding(18)
        .oaGlassCard()
        .padding(.vertical, 6)
    }
}

private struct SettingsHomeView: View {
    @EnvironmentObject private var alarmStore: AlarmStore

    private func napDurationSummary(minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60

        if hours > 0 {
            return "\(hours)h \(mins)m"
        }

        return "\(mins)m"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.settingsDefaultConfigTitle)
                            .font(.headline)
                            .foregroundStyle(OAColor.textPrimary)

                        NavigationLink {
                            DefaultSharedSettingsView()
                        } label: {
                            HStack(spacing: 10) {
                                Text(L10n.settingsDefaultConfigManageButton)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(OAColor.textPrimary)

                                Spacer(minLength: 0)

                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(OAColor.textSecondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: OARadius.button, style: .continuous)
                                    .fill(OAColor.glassFill)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: OARadius.button, style: .continuous)
                                    .stroke(OAColor.glassStroke.opacity(0.7), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(20)
                    .oaGlassCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.settingsNapDefaultsTitle)
                            .font(.headline)
                            .foregroundStyle(OAColor.textPrimary)

                        NavigationLink {
                            NapDefaultDurationView()
                        } label: {
                            HStack(spacing: 10) {
                                Text(L10n.settingsNapDefaultsManageButton)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(OAColor.textPrimary)

                                Spacer(minLength: 0)

                                Text(napDurationSummary(minutes: alarmStore.defaultNapDurationMinutes))
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(OAColor.textSecondary)

                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(OAColor.textSecondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: OARadius.button, style: .continuous)
                                    .fill(OAColor.glassFill)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: OARadius.button, style: .continuous)
                                    .stroke(OAColor.glassStroke.opacity(0.7), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(20)
                    .oaGlassCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.settingsTestingModeTitle)
                            .font(.headline)
                            .foregroundStyle(OAColor.textPrimary)

                        Toggle(isOn: Binding(
                            get: { alarmStore.testingModeEnabled },
                            set: { alarmStore.updateTestingModeEnabled($0) }
                        )) {
                            Text(L10n.settingsTestingModeToggle)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(OAColor.textPrimary)
                        }
                        .tint(OAColor.actionCyan)

                        Button {
                            alarmStore.openSettings()
                        } label: {
                            HStack(spacing: 10) {
                                Text(L10n.actionOpenSettings)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(OAColor.textPrimary)

                                Spacer(minLength: 0)

                                Image(systemName: "arrow.up.right.square")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(OAColor.textSecondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: OARadius.button, style: .continuous)
                                    .fill(OAColor.glassFill)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: OARadius.button, style: .continuous)
                                    .stroke(OAColor.glassStroke.opacity(0.7), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(20)
                    .oaGlassCard()
                }
                .padding(20)
            }
            .background(OAColor.background.ignoresSafeArea())
            .navigationTitle(L10n.settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct DefaultSharedSettingsView: View {
    @EnvironmentObject private var alarmStore: AlarmStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SharedAlarmSettingsEditor(
                    settings: Binding(
                        get: { alarmStore.defaultSharedSettings },
                        set: { alarmStore.updateDefaultSharedSettings($0) }
                    ),
                    allowFiveSecondSnoozeOption: alarmStore.testingModeEnabled
                )
            }
            .padding(20)
            .oaGlassCard()
            .padding(20)
        }
        .background(OAColor.background.ignoresSafeArea())
        .navigationTitle(L10n.settingsDefaultConfigTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NapDefaultDurationView: View {
    @EnvironmentObject private var alarmStore: AlarmStore

    @State private var hours: Int = 0
    @State private var minutes: Int = 35
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                NapDurationPicker(hours: $hours, minutes: $minutes)
            }
            .padding(20)
            .oaGlassCard()
            .padding(20)
        }
        .background(OAColor.background.ignoresSafeArea())
        .navigationTitle(L10n.settingsNapDefaultsTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            setDuration(minutes: alarmStore.defaultNapDurationMinutes)
        }
        .onChange(of: hours) { _, _ in
            saveDuration()
        }
        .onChange(of: self.minutes) { _, _ in
            saveDuration()
        }
    }

    private func setDuration(minutes total: Int) {
        let clamped = max(1, total)
        hours = clamped / 60
        minutes = clamped % 60
    }

    private func saveDuration() {
        guard loaded else {
            return
        }

        let total = max(1, hours * 60 + minutes)
        alarmStore.updateDefaultNapDurationMinutes(total)
    }
}

private struct NapDurationPicker: View {
    @Binding var hours: Int
    @Binding var minutes: Int

    private var minuteOptions: [Int] {
        if hours == 0 {
            return Array(1 ... 59)
        }

        return Array(0 ... 59)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(L10n.napEditorHoursLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(OAColor.textSecondary)

                Picker("", selection: $hours) {
                    ForEach(0 ... 12, id: \.self) { value in
                        Text(value.formatted())
                            .tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 6) {
                Text(L10n.napEditorMinutesLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(OAColor.textSecondary)

                Picker("", selection: $minutes) {
                    ForEach(minuteOptions, id: \.self) { value in
                        Text(String(format: "%02d", value))
                            .tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if hours == 0, minutes == 0 {
                minutes = 1
            }
        }
        .onChange(of: hours) { _, newHours in
            if newHours == 0, minutes == 0 {
                minutes = 1
            }
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(AlarmStore())
}
