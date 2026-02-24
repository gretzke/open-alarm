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

struct AlarmEditorView: View {
    @EnvironmentObject private var alarmStore: AlarmStore
    @Environment(\.dismiss) private var dismiss

    private let route: AlarmEditorRoute

    @State private var draft: AlarmDraft
    @State private var isSaving = false
    @State private var isTryOutSheetPresented = false
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
        .sheet(isPresented: $isTryOutSheetPresented) {
            TryOutPickerView(
                isBusy: isSaving,
                onSelect: { seconds in
                    runTryOut(after: seconds)
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
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
            Text(L10n.alarmEditorSnoozeTitle)
                .font(.headline)
                .foregroundStyle(OAColor.textSecondary)

            VStack(spacing: 0) {
                snoozeDurationRow

                Divider()
                    .overlay(OAColor.glassStroke.opacity(0.8))

                maxSnoozesRow
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
        }
    }

    private var snoozeDurationRow: some View {
        Menu {
            ForEach(snoozeDurationOptions, id: \.self) { minutes in
                Button {
                    draft.snoozeDurationMinutes = minutes
                } label: {
                    if draft.snoozeDurationMinutes == minutes {
                        Label(snoozeDurationDisplay(minutes: minutes), systemImage: "checkmark")
                    } else {
                        Text(snoozeDurationDisplay(minutes: minutes))
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text(L10n.alarmEditorSnoozeDurationLabel)
                    .font(.body)
                    .foregroundStyle(OAColor.textPrimary)

                Spacer(minLength: 0)

                Text(snoozeDurationDisplay(minutes: draft.snoozeDurationMinutes))
                    .font(.body.weight(.medium))
                    .foregroundStyle(OAColor.textSecondary)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote)
                    .foregroundStyle(OAColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private var maxSnoozesRow: some View {
        Menu {
            ForEach(maxSnoozeOptions, id: \.self) { value in
                Button {
                    draft.maxSnoozes = value
                } label: {
                    if draft.maxSnoozes == value {
                        Label(maxSnoozeDisplay(value), systemImage: "checkmark")
                    } else {
                        Text(maxSnoozeDisplay(value))
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text(L10n.alarmEditorSnoozeMaxLabel)
                    .font(.body)
                    .foregroundStyle(OAColor.textPrimary)

                Spacer(minLength: 0)

                Text(maxSnoozeDisplay(draft.maxSnoozes))
                    .font(.body.weight(.medium))
                    .foregroundStyle(OAColor.textSecondary)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote)
                    .foregroundStyle(OAColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private var tryOutSection: some View {
        Button {
            isTryOutSheetPresented = true
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

    private func snoozeDurationDisplay(minutes: Int) -> String {
        "\(minutes) \(String(localized: "alarm_editor_snooze_minutes_unit"))"
    }

    private func maxSnoozeDisplay(_ value: Int?) -> String {
        if let value {
            return "\(value)"
        }
        return String(localized: "alarm_editor_snooze_unlimited")
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
                isTryOutSheetPresented = false
            } catch {
                errorMessage = alarmStore.userFacingErrorMessage(for: error)
            }
            isSaving = false
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
            List(options) { option in
                Button {
                    onSelect(option.seconds)
                } label: {
                    Text(option.label)
                        .foregroundStyle(OAColor.textPrimary)
                }
                .disabled(isBusy)
                .listRowBackground(OAColor.background)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(OAColor.background.ignoresSafeArea())
            .navigationTitle(L10n.tryOutSheetTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
