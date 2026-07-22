import AlarmKit
import Foundation
import SwiftUI

struct SettingsHomeView: View {
    @EnvironmentObject private var alarmStore: AlarmStore
    @State private var showLiveActivitiesSettingsPrompt = false

    private func napDurationSummary(minutes: Int) -> String {
        if minutes == 0 {
            return String(localized: "alarm_editor_snooze_debug_5_seconds")
        }
        let hours = minutes / 60
        let mins = minutes % 60

        if hours > 0 {
            return String(format: String(localized: "duration_hours_minutes_short"), hours, mins)
        }

        return String(format: String(localized: "duration_minutes_short"), mins)
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
                            .frame(maxWidth: .infinity, minHeight: OASize.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("settings_default_config_manage")
                    }
                    .padding(OASpacing.cardPadding)
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
                                    .font(OAType.rowValue)
                                    .foregroundStyle(OAColor.textSecondary)

                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(OAColor.textSecondary)
                            }
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: OASize.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.glass)
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
                            .frame(maxWidth: .infinity, minHeight: OASize.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("settings_nap_defaults_config")
                    }
                    .padding(OASpacing.cardPadding)
                    .oaGlassCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.settingsAlarmSoundTitle)
                            .font(.headline)
                            .foregroundStyle(OAColor.textPrimary)

                        Toggle(isOn: Binding(
                            get: { alarmStore.pinAlarmVolumeEnabled },
                            set: { alarmStore.updatePinAlarmVolumeEnabled($0) }
                        )) {
                            Text(L10n.settingsPinAlarmVolumeToggle)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(OAColor.textPrimary)
                        }
                        .tint(OAColor.actionCyan)

                        Text(L10n.settingsPinAlarmVolumeFootnote)
                            .font(.footnote)
                            .foregroundStyle(OAColor.textSecondary)

                        Text(L10n.settingsTemporaryMuteFootnote)
                            .font(.footnote)
                            .foregroundStyle(OAColor.textSecondary)
                    }
                    .padding(OASpacing.cardPadding)
                    .oaGlassCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.settingsLiveActivitiesTitle)
                            .font(.headline)
                            .foregroundStyle(OAColor.textPrimary)

                        Text(L10n.settingsLiveActivitiesBody)
                            .font(.footnote)
                            .foregroundStyle(OAColor.textSecondary)

                        Toggle(isOn: Binding(
                            get: { alarmStore.liveActivitiesSystemEnabled && alarmStore.liveActivitiesEnabled },
                            set: { newValue in
                                let systemEnabled = alarmStore.refreshLiveActivityAuthorizationStatus()
                                if newValue && !systemEnabled {
                                    showLiveActivitiesSettingsPrompt = true
                                    return
                                }
                                alarmStore.updateLiveActivitiesEnabled(newValue)
                            }
                        )) {
                            Text(L10n.settingsLiveActivitiesGlobalToggle)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(OAColor.textPrimary)
                        }
                        .tint(OAColor.actionCyan)

                        if !alarmStore.liveActivitiesSystemEnabled {
                            Text(L10n.settingsLiveActivitiesSystemDisabledHint)
                                .font(.footnote)
                                .foregroundStyle(OAColor.textSecondary)
                        }

                    }
                    .padding(OASpacing.cardPadding)
                    .oaGlassCard()

                    if alarmStore.testingSectionUnlocked || alarmStore.testingModeEnabled {
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
                                .frame(maxWidth: .infinity, minHeight: OASize.rowHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("settings_open_system_settings")

                            if alarmStore.testingModeEnabled {
                                NavigationLink {
                                    DiagnosticsView()
                                } label: {
                                    HStack(spacing: 10) {
                                        Text(L10n.settingsDiagnosticsTitle)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(OAColor.textPrimary)

                                        Spacer(minLength: 0)

                                        Image(systemName: "chevron.right")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(OAColor.textSecondary)
                                    }
                                    .padding(.horizontal, 16)
                                    .frame(maxWidth: .infinity, minHeight: OASize.rowHeight)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.glass)
                                .accessibilityIdentifier("settings_diagnostics")
                            }
                        }
                        .padding(OASpacing.cardPadding)
                        .oaGlassCard()
                    }

                    NavigationLink {
                        CreditsView()
                    } label: {
                        HStack(spacing: 10) {
                            Text(L10n.settingsCreditsTitle)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(OAColor.textPrimary)

                            Spacer(minLength: 0)

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(OAColor.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: OASize.rowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("settings_credits")
                }
                .padding(OASpacing.screenMargin)
            }
            .background(OAColor.background.ignoresSafeArea())
            .navigationTitle(L10n.settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                alarmStore.refreshLiveActivityAuthorizationStatus()
            }
            .alert(L10n.settingsLiveActivitiesPromptTitle, isPresented: $showLiveActivitiesSettingsPrompt) {
                Button(L10n.actionCancel, role: .cancel) {}
                Button(L10n.actionOpenSettings) {
                    alarmStore.openSettings()
                }
            } message: {
                Text(L10n.settingsLiveActivitiesPromptBody)
            }
        }
    }
}

// MARK: - Supporting Views

private struct DiagnosticsView: View {
    @EnvironmentObject private var alarmStore: AlarmStore
    @State private var entries: [String] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(entries.enumerated().reversed()), id: \.offset) { _, entry in
                    Text(entry)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(OAColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(OASpacing.screenMargin)
        }
        .background(OAColor.background.ignoresSafeArea())
        .navigationTitle(L10n.settingsDiagnosticsTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: diagnosticsExportText) {
                    Text(L10n.actionExport)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.actionClear) {
                    IntentDiagnostics.clear()
                    entries = IntentDiagnostics.entries()
                }
            }
        }
        .onAppear {
            entries = IntentDiagnostics.entries()
        }
    }

    private var diagnosticsExportText: String {
        let dateFormatter = ISO8601DateFormatter()
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let pendingDisarmIDs = alarmStore.pendingDisarmAlarmIDsForDiagnostics
            .map(\.uuidString)
            .sorted()
            .joined(separator: ",")
        let backstopSlots = BackstopSlotStore.allSlots()
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { "\($0.key.uuidString) -> \($0.value.uuidString)" }
            .joined(separator: ", ")
        let wakeCheckSessions = alarmStore.wakeCheckSessions.values
            .sorted { $0.alarmID.uuidString < $1.alarmID.uuidString }
            .map {
                "alarmID=\($0.alarmID.uuidString) cycle=\($0.cycle) checkAt=\(dateFormatter.string(from: $0.checkAt)) deadlineAt=\(dateFormatter.string(from: $0.deadlineAt))"
            }
            .joined(separator: "\n")
        let runtimeRegistrations: String
        if let runtimeAlarms = try? AlarmManager.shared.alarms {
            runtimeRegistrations = runtimeAlarms
                .map { "\($0.id.uuidString):\(String(describing: $0.state))" }
                .joined(separator: ",")
        } else {
            runtimeRegistrations = "read failed"
        }

        return [
            "OpenAlarm Diagnostics",
            "Generated: \(dateFormatter.string(from: .now))",
            "App version: \(appVersion) (\(build))",
            "iOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "",
            "STATE",
            "Pending disarm alarm IDs: [\(pendingDisarmIDs)]",
            "Backstop slots: \(backstopSlots.isEmpty ? "none" : backstopSlots)",
            "Wake-check sessions:",
            wakeCheckSessions.isEmpty ? "none" : wakeCheckSessions,
            "AlarmKit runtime registrations: \(runtimeRegistrations)",
            "",
            "LOG",
            IntentDiagnostics.entries().joined(separator: "\n")
        ].joined(separator: "\n")
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
            .padding(OASpacing.cardPadding)
            .oaGlassCard()
            .padding(OASpacing.screenMargin)
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
                NapDurationPicker(hours: $hours, minutes: $minutes, allowZeroMinutes: alarmStore.testingModeEnabled)
            }
            .padding(OASpacing.cardPadding)
            .oaGlassCard()
            .padding(OASpacing.screenMargin)
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
        let clamped = max(0, total)
        hours = clamped / 60
        minutes = clamped % 60
    }

    private func saveDuration() {
        guard loaded else {
            return
        }

        let total = max(0, hours * 60 + minutes)
        alarmStore.updateDefaultNapDurationMinutes(total)
    }
}

private struct NapDefaultSharedSettingsView: View {
    @EnvironmentObject private var alarmStore: AlarmStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: useGlobalDefaultsBinding) {
                    Text(L10n.settingsNapDefaultsUseGlobalToggle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(OAColor.textPrimary)
                }
                .tint(OAColor.actionCyan)

                Text(L10n.settingsNapDefaultsUseGlobalHint)
                    .font(.footnote)
                    .foregroundStyle(OAColor.textSecondary)

                if !alarmStore.useGlobalDefaultsForNap {
                    SharedAlarmSettingsEditor(
                        settings: napSettingsBinding,
                        allowFiveSecondSnoozeOption: alarmStore.testingModeEnabled
                    )
                }
            }
            .padding(OASpacing.cardPadding)
            .oaGlassCard()
            .padding(OASpacing.screenMargin)
        }
        .background(OAColor.background.ignoresSafeArea())
        .navigationTitle(L10n.settingsNapDefaultsConfigTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var useGlobalDefaultsBinding: Binding<Bool> {
        Binding(
            get: { alarmStore.useGlobalDefaultsForNap },
            set: { useGlobal in
                if useGlobal {
                    alarmStore.updateNapDefaultSharedSettings(nil)
                } else {
                    alarmStore.updateNapDefaultSharedSettings(
                        alarmStore.napDefaultSharedSettings ?? alarmStore.defaultSharedSettings
                    )
                }
            }
        )
    }

    private var napSettingsBinding: Binding<SharedAlarmSettings> {
        Binding(
            get: { alarmStore.napDefaultSharedSettings ?? alarmStore.defaultSharedSettings },
            set: { alarmStore.updateNapDefaultSharedSettings($0) }
        )
    }
}
