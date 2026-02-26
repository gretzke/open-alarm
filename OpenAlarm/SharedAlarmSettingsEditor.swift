import SwiftUI

private enum SharedSettingsSelectionSheet: String, Identifiable {
    case snoozeDuration
    case maxSnoozes

    var id: String { rawValue }
}

private enum SharedSettingsSelectionOption: Hashable {
    case value(Int)
    case unlimited
}

struct SharedAlarmSettingsEditor: View {
    @EnvironmentObject private var alarmStore: AlarmStore

    @Binding var settings: SharedAlarmSettings

    var allowFiveSecondSnoozeOption: Bool = false
    var openSnoozeDurationOnAppearFromLaunchArg: Bool = false

    @State private var selectionSheet: SharedSettingsSelectionSheet?
    @State private var isSchedulingTryOut = false
    @State private var showTryOutToast = false
    @State private var tryOutError: LocalizedStringKey?
    @State private var showWakeCheckPermissionPrompt = false
    @State private var showWakeCheckPermissionDenied = false

    private var snoozeDurationOptions: [Int] {
        if allowFiveSecondSnoozeOption {
            return [0, 1, 3, 5, 10, 15, 20, 30, 45, 60]
        }
        return [1, 3, 5, 10, 15, 20, 30, 45, 60]
    }

    private let maxSnoozeOptions: [Int?] = [nil, 1, 2, 3, 5, 10]
    private let wakeCheckDelayOptions: [Int] = [1, 3, 5, 10, 15, 20, 30, 45, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.alarmEditorSnoozeTitle)
                    .font(.headline)
                    .foregroundStyle(OAColor.textSecondary)

                Spacer(minLength: 0)

                Toggle(isOn: $settings.snoozeEnabled) {
                    EmptyView()
                }
                .labelsHidden()
                .tint(OAColor.actionCyan)
            }

            if settings.snoozeEnabled {
                VStack(spacing: 0) {
                    selectionRow(
                        title: L10n.alarmEditorSnoozeDurationLabel,
                        value: snoozeDurationLabel(for: settings.snoozeDurationMinutes),
                        action: { selectionSheet = .snoozeDuration }
                    )

                    Divider()
                        .overlay(OAColor.glassStroke.opacity(0.8))

                    selectionRow(
                        title: L10n.alarmEditorSnoozeMaxLabel,
                        value: settings.maxSnoozes.map(String.init) ?? String(localized: "alarm_editor_snooze_unlimited"),
                        action: { selectionSheet = .maxSnoozes }
                    )
                }
                .frame(maxWidth: .infinity)
                .oaGlassPanel()
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { settings.wakeUpCheckEnabled },
                    set: { enabled in
                        if enabled {
                            attemptEnableWakeCheck()
                        } else {
                            settings.wakeUpCheckEnabled = false
                        }
                    }
                )) {
                    Text(L10n.alarmEditorWakeCheckToggle)
                        .font(.headline)
                        .foregroundStyle(OAColor.textPrimary)
                }
                .tint(OAColor.actionCyan)

                if settings.wakeUpCheckEnabled {
                    Menu {
                        ForEach(wakeCheckDelayOptions, id: \.self) { minutes in
                            Button {
                                settings.wakeUpCheckDelayMinutes = minutes
                            } label: {
                                Text(snoozeDurationLabel(for: minutes))
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Text(L10n.alarmEditorWakeCheckDelayLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(OAColor.textPrimary)

                            Spacer(minLength: 0)

                            Text(snoozeDurationLabel(for: settings.wakeUpCheckDelayMinutes))
                                .font(.subheadline)
                                .foregroundStyle(OAColor.textSecondary)

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(OAColor.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .oaGlassButtonChrome()
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                runTryOut(after: 5)
            } label: {
                Text(L10n.alarmEditorTryOut)
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(OAColor.actionCyan)
                    .oaGlassProminentButtonChrome()
            }
            .buttonStyle(.plain)
            .disabled(isSchedulingTryOut)

            if let tryOutError {
                Text(tryOutError)
                    .font(.footnote)
                    .foregroundStyle(OAColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
        .onAppear {
#if DEBUG
            if openSnoozeDurationOnAppearFromLaunchArg,
               ProcessInfo.processInfo.arguments.contains("uitestOpenSnoozeDuration") {
                settings.snoozeEnabled = true
                selectionSheet = .snoozeDuration
            }
#endif
        }
        .sheet(item: $selectionSheet) { item in
            SharedSettingsSelectionSheetView(
                title: item == .snoozeDuration ? L10n.alarmEditorSnoozeDurationLabel : L10n.alarmEditorSnoozeMaxLabel,
                options: item == .snoozeDuration
                    ? snoozeDurationOptions.map(SharedSettingsSelectionOption.value)
                    : maxSnoozeOptions.map { $0.map(SharedSettingsSelectionOption.value) ?? .unlimited },
                selected: selectedOption(for: item),
                format: { option in
                    switch option {
                    case let .value(number):
                        if item == .snoozeDuration {
                            return snoozeDurationLabel(for: number)
                        }
                        return "\(number)"
                    case .unlimited:
                        return String(localized: "alarm_editor_snooze_unlimited")
                    }
                },
                onSelect: { option in
                    switch item {
                    case .snoozeDuration:
                        if case let .value(minutes) = option {
                            settings.snoozeDurationMinutes = minutes
                        }
                    case .maxSnoozes:
                        switch option {
                        case let .value(number):
                            settings.maxSnoozes = number
                        case .unlimited:
                            settings.maxSnoozes = nil
                        }
                    }
                    selectionSheet = nil
                }
            )
            .preferredColorScheme(.dark)
            .presentationDetents([.fraction(0.35), .medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(.clear)
            .presentationBackgroundInteraction(.enabled)
        }
        .overlay(alignment: .top) {
            if showTryOutToast {
                Text(L10n.alarmEditorTryOutStartsIn5Seconds)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OAColor.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        Capsule(style: .continuous)
                            .fill(OAColor.background.opacity(0.96))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(OAColor.actionCyan.opacity(0.55), lineWidth: 0.9)
                    )
                    .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 6)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showTryOutToast)
        .task {
            await alarmStore.refreshNotificationPermissionStatus()
        }
        .alert(L10n.alarmEditorWakeCheckPermissionPromptTitle, isPresented: $showWakeCheckPermissionPrompt) {
            Button(L10n.actionNext) {
                requestWakeCheckPermissionAfterPrompt()
            }
            Button(L10n.actionCancel, role: .cancel) {
                settings.wakeUpCheckEnabled = false
            }
        } message: {
            Text(L10n.alarmEditorWakeCheckPermissionPromptBody)
        }
        .alert(L10n.alarmEditorWakeCheckPermissionDeniedTitle, isPresented: $showWakeCheckPermissionDenied) {
            Button(L10n.actionOpenSettings) {
                alarmStore.openSettings()
            }
            Button(L10n.alarmEditorWakeCheckDisableFeatureAction, role: .destructive) {
                settings.wakeUpCheckEnabled = false
                alarmStore.disableWakeUpCheckFeatureGlobally()
            }
            Button(L10n.actionCancel, role: .cancel) {
                settings.wakeUpCheckEnabled = false
            }
        } message: {
            Text(L10n.alarmEditorWakeCheckPermissionDeniedBody)
        }
    }

    private func selectedOption(for item: SharedSettingsSelectionSheet) -> SharedSettingsSelectionOption {
        switch item {
        case .snoozeDuration:
            return .value(settings.snoozeDurationMinutes)
        case .maxSnoozes:
            return settings.maxSnoozes.map(SharedSettingsSelectionOption.value) ?? .unlimited
        }
    }

    private func selectionRow(title: LocalizedStringKey, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(OAColor.textPrimary)

                Spacer(minLength: 0)

                Text(value)
                    .font(.body.weight(.medium))
                    .foregroundStyle(OAColor.textSecondary)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(OAColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private func snoozeDurationLabel(for minutes: Int) -> String {
        if minutes == 0 {
            return String(localized: "alarm_editor_snooze_debug_5_seconds")
        }
        return "\(minutes) \(String(localized: "alarm_editor_snooze_minutes_unit"))"
    }

    private func attemptEnableWakeCheck() {
        Task {
            let status = await alarmStore.refreshNotificationPermissionStatus()
            switch status {
            case .authorized:
                settings.wakeUpCheckEnabled = true
            case .notDetermined:
                showWakeCheckPermissionPrompt = true
            case .denied:
                showWakeCheckPermissionDenied = true
            }
        }
    }

    private func requestWakeCheckPermissionAfterPrompt() {
        Task {
            let status = await alarmStore.requestNotificationPermissionIfNeeded()
            switch status {
            case .authorized:
                settings.wakeUpCheckEnabled = true
            case .notDetermined, .denied:
                settings.wakeUpCheckEnabled = false
                showWakeCheckPermissionDenied = true
            }
        }
    }

    private func runTryOut(after seconds: TimeInterval) {
        guard !isSchedulingTryOut else {
            return
        }

        tryOutError = nil
        isSchedulingTryOut = true

        Task {
            do {
                try await alarmStore.scheduleTryOut(sharedSettings: settings, after: seconds)
                showTryOutToast = true
                Task {
                    try? await Task.sleep(for: .seconds(1.8))
                    showTryOutToast = false
                }
            } catch {
                tryOutError = alarmStore.userFacingErrorMessage(for: error)
            }
            isSchedulingTryOut = false
        }
    }
}

private struct SharedSettingsSelectionSheetView: View {
    let title: LocalizedStringKey
    let options: [SharedSettingsSelectionOption]
    let selected: SharedSettingsSelectionOption
    let format: (SharedSettingsSelectionOption) -> String
    let onSelect: (SharedSettingsSelectionOption) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                GlassEffectContainer(spacing: 10) {
                    VStack(spacing: 10) {
                        ForEach(options, id: \.self) { option in
                            Button {
                                onSelect(option)
                            } label: {
                                HStack {
                                    Text(format(option))
                                        .foregroundStyle(OAColor.textPrimary)
                                    Spacer(minLength: 0)
                                    if option == selected {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(OAColor.actionCyan)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .oaGlassButtonChrome()
                            }
                            .frame(maxWidth: .infinity)
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.clear)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
