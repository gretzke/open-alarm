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

private enum AlarmEditorSelectionSheet: String, Identifiable {
    case snoozeDuration
    case maxSnoozes

    var id: String { rawValue }
}

struct AlarmEditorView: View {
    @EnvironmentObject private var alarmStore: AlarmStore
    @Environment(\.dismiss) private var dismiss

    private let route: AlarmEditorRoute

    @State private var draft: AlarmDraft
    @State private var isSaving = false
    @State private var selectionSheet: AlarmEditorSelectionSheet?
    @State private var errorMessage: LocalizedStringKey?
    @State private var showTryOutToast = false

    private let snoozeDurationOptions = [0, 1, 3, 5, 10, 15, 20, 30, 45, 60]
    private let maxSnoozeOptions: [Int?] = [nil, 1, 2, 3, 5, 10]

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
                    snoozeSection
                    tryOutSection

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
            .background(.clear)
            .navigationTitle(route.existingAlarm == nil ? L10n.alarmEditorNewTitle : L10n.alarmEditorEditTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Text(L10n.actionCancel)
                    }
                    .tint(OAColor.actionCyan)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        saveAlarm()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .tint(OAColor.actionCyan)
                        } else {
                            Text(route.existingAlarm == nil ? L10n.actionAdd : L10n.actionSave)
                        }
                    }
                    .tint(OAColor.actionCyan)
                    .disabled(isSaving)
                }
            }
        }
        .preferredColorScheme(.dark)
        .toolbarBackground(.hidden, for: .navigationBar)
        .presentationBackground(.clear)
        .sheet(item: $selectionSheet) { item in
            sheetContent(for: item)
                .preferredColorScheme(.dark)
                .presentationDetents([.fraction(0.35), .medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.clear)
                .presentationBackgroundInteraction(.enabled)
        }
        .overlay(alignment: .bottom) {
            if showTryOutToast {
                Text(L10n.alarmEditorTryOutStartsIn5Seconds)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OAColor.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        Capsule(style: .continuous)
                            .fill(OAColor.glassFill)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(OAColor.glassStroke.opacity(0.7), lineWidth: 0.8)
                    )
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showTryOutToast)
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

    private var snoozeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.alarmEditorSnoozeTitle)
                    .font(.headline)
                    .foregroundStyle(OAColor.textSecondary)

                Spacer(minLength: 0)

                Toggle(isOn: $draft.snoozeEnabled) {
                    EmptyView()
                }
                .labelsHidden()
                .tint(OAColor.actionCyan)
            }

            if draft.snoozeEnabled {
                VStack(spacing: 0) {
                    selectionRow(
                        title: L10n.alarmEditorSnoozeDurationLabel,
                        value: snoozeDurationLabel(for: draft.snoozeDurationMinutes),
                        action: { selectionSheet = .snoozeDuration }
                    )

                    Divider()
                        .overlay(OAColor.glassStroke.opacity(0.8))

                    selectionRow(
                        title: L10n.alarmEditorSnoozeMaxLabel,
                        value: draft.maxSnoozes.map(String.init) ?? String(localized: "alarm_editor_snooze_unlimited"),
                        action: { selectionSheet = .maxSnoozes }
                    )
                }
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
        }
    }

    private var tryOutSection: some View {
        Button {
            runTryOut(after: 5)
        } label: {
            Text(L10n.alarmEditorTryOut)
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(OAColor.background)
                .background(
                    RoundedRectangle(cornerRadius: OARadius.button, style: .continuous)
                        .fill(OAColor.actionCyan)
                )
                .shadow(color: OAColor.actionCyan.opacity(0.36), radius: 16, x: 0, y: 10)
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
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

    private func snoozeDurationLabel(for minutes: Int) -> String {
        if minutes == 0 {
            return String(localized: "alarm_editor_snooze_debug_5_seconds")
        }
        return "\(minutes) \(String(localized: "alarm_editor_snooze_minutes_unit"))"
    }

    @ViewBuilder
    private func sheetContent(for item: AlarmEditorSelectionSheet) -> some View {
        switch item {
        case .snoozeDuration:
            SelectionSheetView(
                title: L10n.alarmEditorSnoozeDurationLabel,
                options: snoozeDurationOptions.map { .value($0) },
                selected: .value(draft.snoozeDurationMinutes),
                format: { option in
                    switch option {
                    case let .value(minutes):
                        return snoozeDurationLabel(for: minutes)
                    case .unlimited:
                        return String(localized: "alarm_editor_snooze_unlimited")
                    }
                },
                onSelect: { option in
                    if case let .value(minutes) = option {
                        draft.snoozeDurationMinutes = minutes
                    }
                    selectionSheet = nil
                }
            )

        case .maxSnoozes:
            SelectionSheetView(
                title: L10n.alarmEditorSnoozeMaxLabel,
                options: maxSnoozeOptions.map { value in
                    value.map(SelectionOption.value) ?? .unlimited
                },
                selected: draft.maxSnoozes.map(SelectionOption.value) ?? .unlimited,
                format: { option in
                    switch option {
                    case let .value(number):
                        return "\(number)"
                    case .unlimited:
                        return String(localized: "alarm_editor_snooze_unlimited")
                    }
                },
                onSelect: { option in
                    switch option {
                    case let .value(number):
                        draft.maxSnoozes = number
                    case .unlimited:
                        draft.maxSnoozes = nil
                    }
                    selectionSheet = nil
                }
            )
        }
    }

    private func saveAlarm() {
        guard !isSaving else {
            return
        }

        errorMessage = nil
        isSaving = true

        Task {
            do {
                if let existing = route.existingAlarm {
                    try await alarmStore.updateAlarm(existing, with: draft)
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

    private func runTryOut(after seconds: TimeInterval) {
        guard !isSaving else {
            return
        }

        errorMessage = nil
        isSaving = true

        Task {
            do {
                try await alarmStore.scheduleTryOut(from: draft, after: seconds)
                selectionSheet = nil
                showTryOutToast = true
                Task {
                    try? await Task.sleep(for: .seconds(1.8))
                    showTryOutToast = false
                }
            } catch {
                errorMessage = alarmStore.userFacingErrorMessage(for: error)
            }
            isSaving = false
        }
    }
}

private enum SelectionOption: Hashable {
    case value(Int)
    case unlimited
}

private struct SelectionSheetView: View {
    let title: LocalizedStringKey
    let options: [SelectionOption]
    let selected: SelectionOption
    let format: (SelectionOption) -> String
    let onSelect: (SelectionOption) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
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
                            .background(
                                RoundedRectangle(cornerRadius: OARadius.button, style: .continuous)
                                    .fill(Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: OARadius.button, style: .continuous)
                                    .stroke(OAColor.glassStroke.opacity(0.7), lineWidth: 0.8)
                            )
                        }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.plain)
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
