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

    private let editorPartialDetent: PresentationDetent = .fraction(0.82)

    private func presentEditor(_ route: AlarmEditorRoute) {
        editorDetent = editorPartialDetent
        editorRoute = route
    }

    var body: some View {
        NavigationStack {
            Group {
                if alarmStore.alarms.isEmpty {
                    ContentUnavailableView(
                        L10n.alarmListEmptyTitle,
                        systemImage: "alarm",
                        description: Text(L10n.alarmListEmptySubtitle)
                    )
                    .foregroundStyle(OAColor.textSecondary)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
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
                                    Text(L10n.actionDelete)
                                }
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OAColor.background.ignoresSafeArea())
            .navigationTitle(L10n.alarmListTitle)
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
        }
        .sheet(item: $editorRoute) { route in
            AlarmEditorView(route: route)
                .environmentObject(alarmStore)
                .presentationDetents([editorPartialDetent, .large], selection: $editorDetent)
                .presentationDragIndicator(.visible)
        }
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.settingsDefaultConfigTitle)
                            .font(.headline)
                            .foregroundStyle(OAColor.textPrimary)

                        Text(L10n.settingsDefaultConfigBody)
                            .font(.subheadline)
                            .foregroundStyle(OAColor.textSecondary)

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
                        Text(L10n.settingsTestingModeTitle)
                            .font(.headline)
                            .foregroundStyle(OAColor.textPrimary)

                        Text(L10n.settingsTestingModeBody)
                            .font(.subheadline)
                            .foregroundStyle(OAColor.textSecondary)

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
                Text(L10n.settingsDefaultConfigPageBody)
                    .font(.subheadline)
                    .foregroundStyle(OAColor.textSecondary)

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

#Preview {
    MainTabView()
        .environmentObject(AlarmStore())
}
