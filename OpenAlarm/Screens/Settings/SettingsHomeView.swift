import SwiftUI

struct SettingsHomeView: View {
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
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(GlassButtonStyle())
                        .accessibilityIdentifier("settings_default_config_manage")
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
                                Text(L10n.settingsNapDefaultsDurationButton)
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
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(GlassButtonStyle())
                        .accessibilityIdentifier("settings_nap_defaults_duration")

                        NavigationLink {
                            NapDefaultSharedSettingsView()
                        } label: {
                            HStack(spacing: 10) {
                                Text(L10n.settingsNapDefaultsConfigButton)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(OAColor.textPrimary)

                                Spacer(minLength: 0)

                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(OAColor.textSecondary)
                            }
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(GlassButtonStyle())
                        .accessibilityIdentifier("settings_nap_defaults_config")
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
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(GlassButtonStyle())
                        .accessibilityIdentifier("settings_open_system_settings")
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

// MARK: - Supporting Views

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

private struct NapDefaultSharedSettingsView: View {
    @EnvironmentObject private var alarmStore: AlarmStore

    @State private var useGlobalDefaults: Bool = true
    @State private var napSettings: SharedAlarmSettings = .featureDefaults
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $useGlobalDefaults) {
                    Text(L10n.settingsNapDefaultsUseGlobalToggle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(OAColor.textPrimary)
                }
                .tint(OAColor.actionCyan)
                .onChange(of: useGlobalDefaults) { _, newValue in
                    guard loaded else { return }
                    if newValue {
                        alarmStore.updateNapDefaultSharedSettings(nil)
                    } else {
                        napSettings = alarmStore.napDefaultSharedSettings ?? alarmStore.defaultSharedSettings
                        alarmStore.updateNapDefaultSharedSettings(napSettings)
                    }
                }

                Text(L10n.settingsNapDefaultsUseGlobalHint)
                    .font(.footnote)
                    .foregroundStyle(OAColor.textSecondary)

                if !useGlobalDefaults {
                    SharedAlarmSettingsEditor(
                        settings: Binding(
                            get: { napSettings },
                            set: { newValue in
                                napSettings = newValue
                                alarmStore.updateNapDefaultSharedSettings(newValue)
                            }
                        ),
                        allowFiveSecondSnoozeOption: alarmStore.testingModeEnabled
                    )
                }
            }
            .padding(20)
            .oaGlassCard()
            .padding(20)
        }
        .background(OAColor.background.ignoresSafeArea())
        .navigationTitle(L10n.settingsNapDefaultsConfigTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            useGlobalDefaults = alarmStore.useGlobalDefaultsForNap
            napSettings = alarmStore.napDefaultSharedSettings ?? alarmStore.defaultSharedSettings
        }
    }
}
