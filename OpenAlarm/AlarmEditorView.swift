import SwiftUI

enum AlarmEditorRoute: Identifiable, Equatable {
    case create
    case edit(UserAlarm)

    var id: String {
        switch self {
        case .create:
            return "create"
        case let .edit(alarm):
            return alarm.id.uuidString
        }
    }

    var existingAlarm: UserAlarm? {
        switch self {
        case .create:
            return nil
        case let .edit(alarm):
            return alarm
        }
    }

    var initialDraft: AlarmDraft {
        switch self {
        case .create:
            return AlarmDraft(time: defaultNewAlarmDate())
        case let .edit(alarm):
            return AlarmDraft(alarm: alarm)
        }
    }

    private func defaultNewAlarmDate() -> Date {
        Calendar.autoupdatingCurrent.date(byAdding: .minute, value: 1, to: .now) ?? .now
    }
}

private enum AlarmSaveScope {
    case nextOnly
    case schedule
}

struct AlarmEditorView: View {
    @EnvironmentObject private var alarmStore: AlarmStore
    @Environment(\.dismiss) private var dismiss

    private let route: AlarmEditorRoute

    @State private var draft: AlarmDraft
    @State private var isSaving = false
    @State private var errorMessage: LocalizedStringKey?
    @State private var hasInitializedDraft = false
    @State private var showSaveScopePopover = false
    @State private var showWakeCheckPermissionPrompt = false
    @State private var showWakeCheckPermissionDenied = false

    init(route: AlarmEditorRoute) {
        self.route = route
        _draft = State(initialValue: route.initialDraft)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    timeSection
                    labelSection
                    deleteAfterUseSection
                    wakeCheckSection
                    repeatDaysSection
                    useDefaultSharedSettingsSection

                    if !draft.useDefaultSharedSettings {
                        SharedAlarmSettingsEditor(
                            settings: $draft.customSharedSettings,
                            allowFiveSecondSnoozeOption: alarmStore.testingModeEnabled,
                            openSnoozeDurationOnAppearFromLaunchArg: true
                        )
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(OAColor.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color.clear)
            .navigationTitle(route.existingAlarm == nil ? L10n.alarmEditorNewTitle : L10n.alarmEditorEditTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                    }
                    .tint(OAColor.textPrimary)
                    .accessibilityLabel(L10n.actionCancel)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView()
                            .tint(OAColor.actionCyan)
                    } else {
                        Button {
                            if shouldShowSaveScopePrompt {
                                showSaveScopePopover = true
                            } else {
                                saveAlarm(scope: .schedule)
                            }
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.headline.weight(.bold))
                        }
                        .tint(OAColor.actionCyan)
                        .buttonStyle(.glassProminent)
                        .popover(
                            isPresented: $showSaveScopePopover,
                            attachmentAnchor: .rect(.bounds),
                            arrowEdge: .top
                        ) {
                            GlassEffectContainer(spacing: 10) {
                                VStack(alignment: .leading, spacing: 10) {
                                    saveScopeActionButton(title: L10n.alarmEditorApplyNextOnlyOption) {
                                        saveAlarm(scope: .nextOnly)
                                        showSaveScopePopover = false
                                    }

                                    saveScopeActionButton(title: L10n.alarmEditorApplyScheduleOption) {
                                        saveAlarm(scope: .schedule)
                                        showSaveScopePopover = false
                                    }
                                }
                            }
                            .padding(14)
                            .frame(width: 252, alignment: .leading)
                            .presentationCompactAdaptation(.popover)
                        }
                        .accessibilityLabel(route.existingAlarm == nil ? L10n.actionAdd : L10n.actionSave)
                    }
                }
            }
        }
        .background(Color.clear)
        .preferredColorScheme(.dark)
        .presentationBackground(.clear)
        .onAppear {
            guard !hasInitializedDraft else {
                return
            }

            hasInitializedDraft = true

            if route.existingAlarm == nil {
                draft.useDefaultSharedSettings = true
                draft.applyDefaultSharedSettings(alarmStore.defaultSharedSettings)
                draft.wakeUpCheckEnabled = alarmStore.defaultWakeUpCheckDefaults.enabledByDefault
                draft.wakeUpCheckDelayMinutes = alarmStore.defaultWakeUpCheckDefaults.clampedDelayMinutes
                draft.wakeUpCheckDisableSnoozeOnReAlert = alarmStore.defaultWakeUpCheckDefaults.disableSnoozeOnReAlert
            } else if draft.useDefaultSharedSettings {
                draft.applyDefaultSharedSettings(alarmStore.defaultSharedSettings)
            }

#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("uitestOpenSnoozeDuration") {
                draft.useDefaultSharedSettings = false
            }
#endif
        }
        .onChange(of: shouldShowSaveScopePrompt) { _, newValue in
            if !newValue {
                showSaveScopePopover = false
            }
        }
        .task {
            await alarmStore.refreshNotificationPermissionStatus()
        }
        .alert(L10n.alarmEditorWakeCheckPermissionPromptTitle, isPresented: $showWakeCheckPermissionPrompt) {
            Button(L10n.actionNext) {
                requestWakeCheckPermissionAfterPrompt()
            }
            Button(L10n.actionCancel, role: .cancel) { }
        } message: {
            Text(L10n.alarmEditorWakeCheckPermissionPromptBody)
        }
        .alert(L10n.alarmEditorWakeCheckPermissionDeniedTitle, isPresented: $showWakeCheckPermissionDenied) {
            Button(L10n.actionOpenSettings) {
                alarmStore.openSettings()
            }
            Button(L10n.alarmEditorWakeCheckDisableFeatureAction, role: .destructive) {
                alarmStore.disableWakeUpCheckFeatureGlobally()
                draft.wakeUpCheckEnabled = false
            }
            Button(L10n.actionCancel, role: .cancel) {
                draft.wakeUpCheckEnabled = false
            }
        } message: {
            Text(L10n.alarmEditorWakeCheckPermissionDeniedBody)
        }
    }

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.alarmEditorTimeTitle)
                .font(.headline)
                .foregroundStyle(OAColor.textSecondary)

            DatePicker(
                "",
                selection: $draft.time,
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .colorScheme(.dark)
            .frame(maxWidth: .infinity)
        }
    }

    private var labelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.alarmEditorLabelTitle)
                .font(.headline)
                .foregroundStyle(OAColor.textSecondary)

            TextField(
                "",
                text: $draft.name,
                prompt: Text(L10n.alarmEditorDefaultLabel)
                    .foregroundStyle(OAColor.textSecondary)
            )
            .textInputAutocapitalization(.sentences)
            .disableAutocorrection(true)
            .foregroundStyle(OAColor.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: OARadius.button, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: OARadius.button, style: .continuous)
                    .stroke(OAColor.glassStroke.opacity(0.7), lineWidth: 0.8)
            )
        }
    }

    private var deleteAfterUseSection: some View {
        Toggle(isOn: Binding(
            get: { draft.deleteAfterUse },
            set: { draft.setDeleteAfterUse($0) }
        )) {
            Text(L10n.alarmEditorDeleteAfterUseToggle)
                .font(.headline)
                .foregroundStyle(OAColor.textPrimary)
        }
        .tint(OAColor.actionCyan)
    }

    private var wakeCheckSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { draft.wakeUpCheckEnabled },
                set: { enabled in
                    if enabled {
                        attemptEnableWakeCheckInEditor()
                    } else {
                        draft.wakeUpCheckEnabled = false
                    }
                }
            )) {
                Text(L10n.alarmEditorWakeCheckToggle)
                    .font(.headline)
                    .foregroundStyle(OAColor.textPrimary)
            }
            .tint(OAColor.actionCyan)

            if draft.wakeUpCheckEnabled {
                Menu {
                    ForEach([1, 3, 5, 10, 15, 20, 30, 45, 60], id: \.self) { minutes in
                        Button {
                            draft.wakeUpCheckDelayMinutes = minutes
                        } label: {
                            Text(wakeCheckDelayLabel(minutes))
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(L10n.alarmEditorWakeCheckDelayLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(OAColor.textPrimary)

                        Spacer(minLength: 0)

                        Text(wakeCheckDelayLabel(draft.wakeUpCheckDelayMinutes))
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

                Toggle(isOn: $draft.wakeUpCheckDisableSnoozeOnReAlert) {
                    Text(L10n.alarmEditorWakeCheckNoSnoozeToggle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(OAColor.textPrimary)
                }
                .tint(OAColor.actionCyan)
            }
        }
    }

    private var repeatDaysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.alarmEditorRepeatDaysTitle)
                .font(.headline)
                .foregroundStyle(OAColor.textSecondary)

            HStack(spacing: 8) {
                ForEach(AlarmWeekday.orderedForCurrentLocale()) { day in
                    dayChip(for: day)
                }
            }
        }
    }

    private var useDefaultSharedSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { draft.useDefaultSharedSettings },
                set: { useDefault in
                    draft.useDefaultSharedSettings = useDefault
                    draft.applyDefaultSharedSettings(alarmStore.defaultSharedSettings)
                }
            )) {
                Text(L10n.alarmEditorUseDefaultSettingsToggle)
                    .font(.headline)
                    .foregroundStyle(OAColor.textPrimary)
            }
            .tint(OAColor.actionCyan)

            Text(L10n.alarmEditorUseDefaultSettingsHint)
                .font(.footnote)
                .foregroundStyle(OAColor.textSecondary)
        }
    }

    // Try-out action lives in SharedAlarmSettingsEditor.

    private func dayChip(for day: AlarmWeekday) -> some View {
        let isSelected = draft.repeatDays.contains(day)

        return Button {
            draft.toggleRepeatDay(day)
        } label: {
            Text(day.veryShortSymbol())
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(isSelected ? OAColor.background : OAColor.textPrimary)
                .background(
                    RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous)
                        .fill(isSelected ? OAColor.actionCyan : OAColor.glassFill)
                )
        }
        .buttonStyle(.plain)
    }

    private func wakeCheckDelayLabel(_ minutes: Int) -> String {
        "\(minutes) \(String(localized: "alarm_editor_snooze_minutes_unit"))"
    }

    private func attemptEnableWakeCheckInEditor() {
        Task {
            let status = await alarmStore.refreshNotificationPermissionStatus()
            switch status {
            case .authorized:
                draft.wakeUpCheckEnabled = true
                draft.wakeUpCheckDelayMinutes = alarmStore.defaultWakeUpCheckDefaults.clampedDelayMinutes
                draft.wakeUpCheckDisableSnoozeOnReAlert = alarmStore.defaultWakeUpCheckDefaults.disableSnoozeOnReAlert
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
                draft.wakeUpCheckEnabled = true
                draft.wakeUpCheckDelayMinutes = alarmStore.defaultWakeUpCheckDefaults.clampedDelayMinutes
                draft.wakeUpCheckDisableSnoozeOnReAlert = alarmStore.defaultWakeUpCheckDefaults.disableSnoozeOnReAlert
            case .notDetermined, .denied:
                draft.wakeUpCheckEnabled = false
                showWakeCheckPermissionDenied = true
            }
        }
    }

    private func saveScopeActionButton(title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OAColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .oaGlassProminentButtonChrome()
        }
        .buttonStyle(.plain)
    }

    // Save actions are handled directly in the toolbar button/menu.

    private var shouldShowSaveScopePrompt: Bool {
        guard let existing = route.existingAlarm, existing.isRepeating else {
            return false
        }

        let existingRepeatDays = Set(existing.repeatDays)
        let draftRepeatDays = draft.repeatDays

        guard existingRepeatDays == draftRepeatDays else {
            return false
        }

        let calendar = Calendar.autoupdatingCurrent
        let existingComponents = calendar.dateComponents([.hour, .minute], from: existing.triggerDateForDisplay)
        let existingTime = (existingComponents.hour ?? existing.hour, existingComponents.minute ?? existing.minute)
        let draftComponents = calendar.dateComponents([.hour, .minute], from: draft.time)
        let draftTime = (draftComponents.hour ?? existing.hour, draftComponents.minute ?? existing.minute)

        guard existingTime != draftTime else {
            return false
        }

        let normalizedExistingName = existing.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDraftName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)

        let otherFieldsUnchanged =
            normalizedExistingName == normalizedDraftName &&
            existing.deleteAfterUse == draft.deleteAfterUse &&
            existing.wakeUpCheckEnabled == draft.wakeUpCheckEnabled &&
            existing.useDefaultSharedSettings == draft.useDefaultSharedSettings &&
            existing.customSharedSettings == draft.customSharedSettings

        return otherFieldsUnchanged
    }

    private func saveAlarm(scope: AlarmSaveScope) {
        guard !isSaving else {
            return
        }

        errorMessage = nil
        isSaving = true

        Task {
            do {
                if let existing = route.existingAlarm {
                    switch scope {
                    case .nextOnly:
                        try await alarmStore.updateNextAlarmOccurrence(existing, with: draft)
                    case .schedule:
                        try await alarmStore.updateAlarm(existing, with: draft, clearNextOverride: shouldShowSaveScopePrompt)
                    }
                } else {
                    try await alarmStore.createAlarm(from: draft)
                }
                dismiss()
            } catch {
                errorMessage = alarmStore.userFacingErrorMessage(for: error)
            }
            isSaving = false
        }
    }

}
