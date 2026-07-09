import SwiftUI

private enum SharedSettingsSelectionSheet: String, Identifiable {
    case snoozeDuration
    case maxSnoozes
    case wakeCheckDelay
    case wakeCheckResponseTimeout

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

    private var wakeCheckDelayOptions: [Int] {
        var options = WakeUpCheckTimingPolicy.checkDelayOptionsMinutes
        if allowFiveSecondSnoozeOption {
            options.insert(WakeUpCheckTimingPolicy.debugFiveSecondSentinelMinutes, at: 0)
        }
        return options
    }

    private var wakeCheckResponseTimeoutOptions: [Int] {
        var options = WakeUpCheckTimingPolicy.responseTimeoutOptionsMinutes
        if allowFiveSecondSnoozeOption {
            options.insert(WakeUpCheckTimingPolicy.debugFiveSecondSentinelMinutes, at: 0)
        }
        return options
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(L10n.alarmEditorTaskVolumeTitle)
                    .font(.headline)
                    .foregroundStyle(OAColor.textPrimary)

                Spacer(minLength: 0)

                Text(verbatim: "\(settings.volume.targetPercent)%")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(OAColor.textSecondary)
            }

            Slider(
                value: Binding(
                    get: { Double(settings.volume.targetPercent) },
                    set: { settings.volume = AlarmVolumeSettings(targetPercent: Int($0.rounded())) }
                ),
                in: 0...100,
                step: 1
            )
            .tint(OAColor.actionCyan)

            Text(L10n.alarmEditorTaskVolumeExplainer)
                .font(.footnote)
                .foregroundStyle(OAColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .oaGlassPanel()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            volumeSection

            HStack {
                Text(L10n.alarmEditorSnoozeTitle)
                    .font(.headline)
                    .foregroundStyle(OAColor.textPrimary)

                Spacer(minLength: 0)

                Toggle(isOn: $settings.snoozeEnabled) {
                    // Hidden visually, but gives VoiceOver a meaningful switch label.
                    Text(L10n.alarmEditorSnoozeTitle)
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
                    VStack(spacing: 0) {
                        selectionRow(
                            title: L10n.alarmEditorWakeCheckDelayLabel,
                            value: snoozeDurationLabel(for: settings.wakeUpCheckDelayMinutes),
                            action: { selectionSheet = .wakeCheckDelay }
                        )

                        Divider()
                            .overlay(OAColor.glassStroke.opacity(0.8))

                        selectionRow(
                            title: L10n.alarmEditorWakeCheckResponseTimeoutLabel,
                            value: snoozeDurationLabel(for: settings.wakeUpCheckResponseTimeoutMinutes),
                            action: { selectionSheet = .wakeCheckResponseTimeout }
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .oaGlassPanel()
                }
            }

            TaskPickerView(tasks: $settings.tasks)

            Button {
                runTryOut(after: 5)
            } label: {
                Text(L10n.alarmEditorTryOut)
                    .font(OAType.buttonLabel)
                    .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
            }
            .buttonStyle(.glassProminent)
                    .tint(OAColor.actionCyan)
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
                title: selectionTitle(for: item),
                options: options(for: item),
                selected: selectedOption(for: item),
                format: { option in
                    optionLabel(option, for: item)
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
                    case .wakeCheckDelay:
                        if case let .value(minutes) = option {
                            settings.wakeUpCheckDelayMinutes = minutes
                        }
                    case .wakeCheckResponseTimeout:
                        if case let .value(minutes) = option {
                            settings.wakeUpCheckResponseTimeoutMinutes = minutes
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

    private func selectionTitle(for item: SharedSettingsSelectionSheet) -> LocalizedStringKey {
        switch item {
        case .snoozeDuration:
            return L10n.alarmEditorSnoozeDurationLabel
        case .maxSnoozes:
            return L10n.alarmEditorSnoozeMaxLabel
        case .wakeCheckDelay:
            return L10n.alarmEditorWakeCheckDelayLabel
        case .wakeCheckResponseTimeout:
            return L10n.alarmEditorWakeCheckResponseTimeoutLabel
        }
    }

    private func options(for item: SharedSettingsSelectionSheet) -> [SharedSettingsSelectionOption] {
        switch item {
        case .snoozeDuration:
            return snoozeDurationOptions.map(SharedSettingsSelectionOption.value)
        case .maxSnoozes:
            return maxSnoozeOptions.map { $0.map(SharedSettingsSelectionOption.value) ?? .unlimited }
        case .wakeCheckDelay:
            return wakeCheckDelayOptions.map(SharedSettingsSelectionOption.value)
        case .wakeCheckResponseTimeout:
            return wakeCheckResponseTimeoutOptions.map(SharedSettingsSelectionOption.value)
        }
    }

    private func selectedOption(for item: SharedSettingsSelectionSheet) -> SharedSettingsSelectionOption {
        switch item {
        case .snoozeDuration:
            return .value(settings.snoozeDurationMinutes)
        case .maxSnoozes:
            return settings.maxSnoozes.map(SharedSettingsSelectionOption.value) ?? .unlimited
        case .wakeCheckDelay:
            return .value(settings.wakeUpCheckDelayMinutes)
        case .wakeCheckResponseTimeout:
            return .value(settings.wakeUpCheckResponseTimeoutMinutes)
        }
    }

    private func optionLabel(_ option: SharedSettingsSelectionOption, for item: SharedSettingsSelectionSheet) -> String {
        switch option {
        case let .value(number):
            switch item {
            case .snoozeDuration, .wakeCheckDelay, .wakeCheckResponseTimeout:
                return snoozeDurationLabel(for: number)
            case .maxSnoozes:
                return "\(number)"
            }
        case .unlimited:
            return String(localized: "alarm_editor_snooze_unlimited")
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
                    .font(OAType.rowValue)
                    .foregroundStyle(OAColor.textSecondary)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(OAColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
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
            .padding(OASpacing.onboardingMargin)
            .oaGlassCard()

            Button(action: onRequestPermission) {
                Text(L10n.actionNext)
                    .font(OAType.buttonLabel)
                    .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
            }
            .buttonStyle(.glassProminent)
                .tint(OAColor.actionCyan)
                .accessibilityIdentifier("wake_check_permission_next")
        }
        .padding(OASpacing.onboardingMargin)
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
            .padding(OASpacing.onboardingMargin)
            .oaGlassCard()

            VStack(spacing: 12) {
                Button(action: onOpenSettings) {
                    Text(L10n.actionOpenSettings)
                        .font(OAType.buttonLabel)
                        .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
                }
                .buttonStyle(.glassProminent)
                .tint(OAColor.actionCyan)
                .accessibilityIdentifier("wake_check_permission_open_settings")

                Button(action: onDisableFeature) {
                    Text(L10n.alarmEditorWakeCheckDisableFeatureAction)
                        .font(OAType.buttonLabel)
                        .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
                }
                .buttonStyle(.glass)
                .foregroundStyle(OAColor.textPrimary)
                .accessibilityIdentifier("wake_check_permission_disable_feature")
            }
        }
        .padding(OASpacing.onboardingMargin)
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
            ScrollViewReader { proxy in
                ScrollView {
                    GlassEffectContainer(spacing: 10) {
                        VStack(spacing: 10) {
                            ForEach(options, id: \.self) { option in
                                let isSelected = option == selected

                                Button {
                                    onSelect(option)
                                } label: {
                                    HStack {
                                        Text(format(option))
                                            .foregroundStyle(OAColor.textPrimary)
                                        Spacer(minLength: 0)
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(OAColor.actionCyan)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .frame(maxWidth: .infinity, minHeight: OASize.rowHeight, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.glassAccentBorder)
                                .tint(OAColor.actionCyan)
                                .id(option)
                            }
                        }
                    }
                    .padding(OASpacing.screenMargin)
                }
                .background(Color.clear)
                .onAppear {
                    // Scroll to selected option with a slight delay to ensure layout is ready
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation {
                            proxy.scrollTo(selected, anchor: .center)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
