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

private enum WakeCheckPermissionFlowStep: String, Identifiable {
    case prePrompt
    case denied

    var id: String { rawValue }
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
    @State private var wakeCheckPermissionFlowStep: WakeCheckPermissionFlowStep?

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
                    .foregroundStyle(OAColor.textPrimary)

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
                        guard enabled else {
                            settings.wakeUpCheckEnabled = false
                            return
                        }

                        var candidate = settings
                        candidate.wakeUpCheckEnabled = true

                        if candidate.hasFeatureRequirement(.notifications) {
                            attemptEnableWakeCheck()
                        } else {
                            settings.wakeUpCheckEnabled = true
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
        .fullScreenCover(item: $wakeCheckPermissionFlowStep) { step in
            switch step {
            case .prePrompt:
                WakeCheckPermissionPrePromptView {
                    requestWakeCheckPermissionAfterPrompt()
                }
            case .denied:
                WakeCheckPermissionDeniedView(
                    onOpenSettings: {
                        wakeCheckPermissionFlowStep = nil
                        alarmStore.openSettings()
                    },
                    onDisableFeature: {
                        settings.wakeUpCheckEnabled = false
                        alarmStore.disableWakeUpCheckFeatureGlobally()
                        wakeCheckPermissionFlowStep = nil
                    }
                )
            }
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
                wakeCheckPermissionFlowStep = nil
            case .notDetermined:
                settings.wakeUpCheckEnabled = false
                wakeCheckPermissionFlowStep = .prePrompt
            case .denied:
                settings.wakeUpCheckEnabled = false
                wakeCheckPermissionFlowStep = .denied
            }
        }
    }

    private func requestWakeCheckPermissionAfterPrompt() {
        Task {
            let status = await alarmStore.requestNotificationPermissionIfNeeded()
            switch status {
            case .authorized:
                settings.wakeUpCheckEnabled = true
                wakeCheckPermissionFlowStep = nil
            case .notDetermined, .denied:
                settings.wakeUpCheckEnabled = false
                wakeCheckPermissionFlowStep = .denied
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

private struct WakeCheckPermissionPrePromptView: View {
    let onRequestPermission: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.bubble")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(OAColor.actionCyan)

                Text(L10n.alarmEditorWakeCheckPermissionPromptTitle)
                    .font(.title.bold())
                    .foregroundStyle(OAColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(L10n.alarmEditorWakeCheckPermissionPromptBody)
                    .font(.body)
                    .foregroundStyle(OAColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .oaGlassCard()

            Button(action: onRequestPermission) {
                Text(L10n.actionNext)
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(OAColor.textPrimary)
                    .oaGlassProminentButtonChrome()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("wake_check_permission_next")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OAColor.background.ignoresSafeArea())
    }
}

struct WakeCheckPermissionDeniedView: View {
    let onOpenSettings: () -> Void
    let onDisableFeature: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(OAColor.danger)

                Text(L10n.alarmEditorWakeCheckPermissionDeniedTitle)
                    .font(.title.bold())
                    .foregroundStyle(OAColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(L10n.alarmEditorWakeCheckPermissionDeniedBody)
                    .font(.body)
                    .foregroundStyle(OAColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .oaGlassCard()

            VStack(spacing: 12) {
                Button(action: onOpenSettings) {
                    Text(L10n.actionOpenSettings)
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(OAColor.textPrimary)
                        .oaGlassProminentButtonChrome()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wake_check_permission_open_settings")

                Button(action: onDisableFeature) {
                    Text(L10n.alarmEditorWakeCheckDisableFeatureAction)
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .foregroundStyle(OAColor.textPrimary)
                .oaGlassButtonChrome()
                .buttonStyle(.plain)
                .accessibilityIdentifier("wake_check_permission_disable_feature")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OAColor.background.ignoresSafeArea())
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
