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
    @State private var baselineDraft: AlarmDraft?
    @State private var showSaveScopePopover = false

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
                .padding(.horizontal, OASpacing.screenMargin)
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
                            .font(OAType.buttonLabel)
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
                        .contentShape(Rectangle())
                        .popover(isPresented: $showSaveScopePopover) {
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

            if route.existingAlarm == nil {
                draft.useDefaultSharedSettings = true
                draft.applyDefaultSharedSettings(alarmStore.defaultSharedSettings)
            } else if draft.useDefaultSharedSettings {
                draft.applyDefaultSharedSettings(alarmStore.defaultSharedSettings)
            }

#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("uitestOpenSnoozeDuration") {
                draft.useDefaultSharedSettings = false
            }
#endif
            baselineDraft = draft
            hasInitializedDraft = true
        }
        .onChange(of: shouldShowSaveScopePrompt) { _, newValue in
            if !newValue {
                showSaveScopePopover = false
            }
        }
    }

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.alarmEditorTimeTitle)
                .font(OAType.sectionLabel)
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

            if let existing = route.existingAlarm,
               existing.activeOverride?.kind == .modifyNext,
               let overrideDate = existing.nextTriggerOverrideDate,
               overrideDate > .now {
                Text(L10n.alarmEditorNextOccurrenceNote(
                    overrideDate.formatted(date: .omitted, time: .shortened)
                ))
                .font(.footnote)
                .foregroundStyle(OAColor.textSecondary)
            }
        }
    }

    private var labelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.alarmEditorLabelTitle)
                .font(OAType.sectionLabel)
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

    private var repeatDaysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.alarmEditorRepeatDaysTitle)
                .font(OAType.sectionLabel)
                .foregroundStyle(OAColor.textSecondary)

            HStack(spacing: 8) {
                ForEach(AlarmWeekday.orderedForCurrentLocale()) { day in
                    dayChip(for: day)
                }
            }

            HStack(spacing: 8) {
                repeatDayPresetChip(
                    title: L10n.alarmEditorRepeatEveryDay,
                    days: AlarmDraft.everyDayRepeatDays
                )
                repeatDayPresetChip(
                    title: L10n.alarmEditorRepeatWeekdays,
                    days: AlarmDraft.weekdayRepeatDays
                )
                repeatDayPresetChip(
                    title: L10n.alarmEditorRepeatWeekend,
                    days: AlarmDraft.weekendRepeatDays
                )
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

        return repeatDayChip(
            label: Text(day.veryShortSymbol()),
            isSelected: isSelected
        ) {
            Haptics.selection()
            draft.toggleRepeatDay(day)
        }
    }

    private func repeatDayPresetChip(
        title: LocalizedStringKey,
        days: Set<AlarmWeekday>
    ) -> some View {
        repeatDayChip(
            label: Text(title),
            isSelected: draft.repeatDaysMatch(days)
        ) {
            Haptics.selection()
            draft.setRepeatDays(days)
        }
    }

    private func repeatDayChip(
        label: Text,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: OASize.minTouchTarget)
                .foregroundStyle(isSelected ? OAColor.background : OAColor.textPrimary)
                .background(
                    RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous)
                        .fill(isSelected ? OAColor.actionCyan : OAColor.glassFill)
                )
                .contentShape(RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func saveScopeActionButton(title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OAColor.textPrimary)
                .frame(maxWidth: .infinity, minHeight: OASize.minTouchTarget, alignment: .leading)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
    }

    // Save actions are handled directly in the toolbar button/menu.

    private var shouldShowSaveScopePrompt: Bool {
        guard let existing = route.existingAlarm else {
            return false
        }

        return AlarmSaveScopePolicy.shouldPrompt(
            existing: existing,
            draft: draft,
            defaults: alarmStore.defaultSharedSettings
        )
    }

    private func saveAlarm(scope: AlarmSaveScope) {
        guard !isSaving else {
            return
        }

        if route.existingAlarm != nil, let baselineDraft, draft == baselineDraft {
            dismiss()
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
                Haptics.success()
                dismiss()
            } catch {
                errorMessage = alarmStore.userFacingErrorMessage(for: error)
            }
            isSaving = false
        }
    }

}
