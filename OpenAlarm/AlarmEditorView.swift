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
    @State private var showSaveScopePrompt = false

    @Namespace private var saveScopeAnimation

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
                    Button {
                        primarySaveTapped()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .tint(OAColor.actionCyan)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.headline.weight(.semibold))
                                .opacity(showSaveScopePrompt ? 0 : 1)
                        }
                    }
                    .tint(OAColor.actionCyan)
                    .disabled(isSaving)
                    .accessibilityLabel(route.existingAlarm == nil ? L10n.actionAdd : L10n.actionSave)
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
            } else if draft.useDefaultSharedSettings {
                draft.applyDefaultSharedSettings(alarmStore.defaultSharedSettings)
            }

#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("uitestOpenSnoozeDuration") {
                draft.useDefaultSharedSettings = false
            }
#endif
        }
        .overlay {
            if showSaveScopePrompt {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismissSaveScopePrompt()
                    }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showSaveScopePrompt {
                SaveScopePromptView(
                    namespace: saveScopeAnimation,
                    onNextOnly: {
                        dismissSaveScopePrompt()
                        saveAlarm(scope: .nextOnly)
                    },
                    onSchedule: {
                        dismissSaveScopePrompt()
                        saveAlarm(scope: .schedule)
                    }
                )
                .padding(.top, 88)
                .padding(.trailing, 16)
                .transition(.scale(scale: 0.84, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showSaveScopePrompt)
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

    private func primarySaveTapped() {
        guard !isSaving else {
            return
        }

        if shouldShowSaveScopePrompt {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                showSaveScopePrompt = true
            }
            return
        }

        saveAlarm(scope: .schedule)
    }

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

    private func dismissSaveScopePrompt() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            showSaveScopePrompt = false
        }
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
                        try await alarmStore.updateAlarm(existing, with: draft)
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

private struct SaveScopePromptView: View {
    let namespace: Namespace.ID
    let onNextOnly: () -> Void
    let onSchedule: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.alarmEditorApplyChangePrompt)
                .font(.headline)
                .foregroundStyle(OAColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                Button(action: onNextOnly) {
                    Text(L10n.alarmEditorApplyNextOnlyOption)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(OAColor.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
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

                Button(action: onSchedule) {
                    Text(L10n.alarmEditorApplyScheduleOption)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(OAColor.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
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
        }
        .padding(16)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(OAColor.background.opacity(0.92))
                .matchedGeometryEffect(id: "save_scope_morph", in: namespace)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(OAColor.glassStroke.opacity(0.8), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.2), radius: 22, x: 0, y: 12)
    }
}
