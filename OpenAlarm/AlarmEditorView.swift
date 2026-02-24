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
    case tryOut

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

    private let snoozeDurationOptions = [1, 3, 5, 10, 15, 20, 30, 45, 60]
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
            .background(OAColor.background.ignoresSafeArea())
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
        .sheet(item: $selectionSheet) { item in
            sheetContent(for: item)
                .preferredColorScheme(.dark)
                .presentationDetents([.fraction(0.35), .medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
                .presentationBackgroundInteraction(.enabled)
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
                        value: "\(draft.snoozeDurationMinutes) \(String(localized: "alarm_editor_snooze_minutes_unit"))",
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
                        .stroke(OAColor.glassStroke, lineWidth: 1)
                )
                .shadow(color: OAColor.glassGlow.opacity(0.7), radius: 10, x: 0, y: 6)
            }
        }
    }

    private var tryOutSection: some View {
        Button {
            selectionSheet = .tryOut
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
                        return "\(minutes) \(String(localized: "alarm_editor_snooze_minutes_unit"))"
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

        case .tryOut:
            TryOutPickerView(
                isBusy: isSaving,
                onSelect: { seconds in
                    runTryOut(after: seconds)
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
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: OARadius.button, style: .continuous)
                                    .fill(OAColor.glassFill)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: OARadius.button, style: .continuous)
                                    .stroke(OAColor.glassStroke, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct TryOutOption: Identifiable {
    let id = UUID()
    let seconds: TimeInterval
    let label: LocalizedStringKey
}

private struct TryOutPickerView: View {
    let isBusy: Bool
    let onSelect: (TimeInterval) -> Void

    private let options: [TryOutOption] = [
        TryOutOption(seconds: 5, label: L10n.tryOutOption5Seconds),
        TryOutOption(seconds: 10, label: L10n.tryOutOption10Seconds),
        TryOutOption(seconds: 30, label: L10n.tryOutOption30Seconds),
        TryOutOption(seconds: 60, label: L10n.tryOutOption1Minute),
        TryOutOption(seconds: 120, label: L10n.tryOutOption2Minutes),
        TryOutOption(seconds: 300, label: L10n.tryOutOption5Minutes)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(options) { option in
                        Button {
                            onSelect(option.seconds)
                        } label: {
                            HStack {
                                Text(option.label)
                                    .foregroundStyle(OAColor.textPrimary)
                                Spacer(minLength: 0)
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
                                    .stroke(OAColor.glassStroke, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                    }
                }
                .padding(20)
            }
            .navigationTitle(L10n.tryOutSheetTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
