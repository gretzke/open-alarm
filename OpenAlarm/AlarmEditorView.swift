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

    init(route: AlarmEditorRoute) {
        self.route = route
        _draft = State(initialValue: route.initialDraft)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    timeCard
                    behaviorCard
                    tryOutCard

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(OAColor.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(20)
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

    private var timeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.alarmEditorTimeTitle)
                .font(.headline)
                .foregroundStyle(OAColor.textPrimary)

            DatePicker(
                "",
                selection: $draft.time,
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .colorScheme(.dark)
        }
        .padding(20)
        .oaGlassCard()
    }

    private var behaviorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.alarmEditorBehaviorTitle)
                .font(.headline)
                .foregroundStyle(OAColor.textPrimary)

            Toggle(isOn: Binding(
                get: { draft.deleteAfterUse },
                set: { draft.setDeleteAfterUse($0) }
            )) {
                Text(L10n.alarmEditorDeleteAfterUseToggle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(OAColor.textPrimary)
            }
            .tint(OAColor.actionCyan)

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.alarmEditorRepeatDaysTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OAColor.textSecondary)

                HStack(spacing: 8) {
                    ForEach(AlarmWeekday.orderedForCurrentLocale()) { day in
                        dayChip(for: day)
                    }
                }
            }
        }
        .padding(20)
        .oaGlassCard()
    }

    private var tryOutCard: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            Text(L10n.alarmEditorTryOutDescription)
                .font(.footnote)
                .foregroundStyle(OAColor.textSecondary)
        }
        .padding(20)
        .oaGlassCard()
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
                .overlay(
                    RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous)
                        .stroke(OAColor.glassStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
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
