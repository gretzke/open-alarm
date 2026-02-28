import SwiftUI

struct NapEditorView: View {
    @EnvironmentObject private var alarmStore: AlarmStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: NapDraft
    @State private var isSaving = false
    @State private var errorMessage: LocalizedStringKey?

    init(initialDraft: NapDraft) {
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    durationSection
                    useDefaultSharedSettingsSection

                    if !draft.useDefaultSharedSettings {
                        SharedAlarmSettingsEditor(
                            settings: $draft.customSharedSettings,
                            allowFiveSecondSnoozeOption: alarmStore.testingModeEnabled
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
            .navigationTitle(L10n.napEditorTitle)
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
                        startNap()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .tint(OAColor.actionCyan)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.headline.weight(.bold))
                        }
                    }
                    .tint(OAColor.actionCyan)
                    .buttonStyle(.glassProminent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .disabled(isSaving)
                    .accessibilityLabel(L10n.napEditorStartButton)
                }
            }
        }
        .background(Color.clear)
        .preferredColorScheme(.dark)
        .presentationBackground(.clear)
        .onAppear {
            if draft.useDefaultSharedSettings {
                draft.applyDefaultSharedSettings(alarmStore.defaultSharedSettings)
            }
        }
    }

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.napEditorDurationTitle)
                .font(.headline)
                .foregroundStyle(OAColor.textSecondary)

            NapDurationEditorPicker(hours: $draft.durationHours, minutes: $draft.durationMinutes)
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

    private func startNap() {
        guard !isSaving else {
            return
        }

        errorMessage = nil
        isSaving = true

        Task {
            do {
                try await alarmStore.createNap(from: draft)
                dismiss()
            } catch {
                errorMessage = alarmStore.userFacingErrorMessage(for: error)
            }
            isSaving = false
        }
    }
}

private struct NapDurationEditorPicker: View {
    @Binding var hours: Int
    @Binding var minutes: Int

    private var minuteOptions: [Int] {
        if hours == 0 {
            return Array(1 ... 59)
        }

        return Array(0 ... 59)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(L10n.napEditorHoursLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(OAColor.textSecondary)

                Picker("", selection: $hours) {
                    ForEach(0 ... 12, id: \.self) { value in
                        Text(value.formatted())
                            .tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 6) {
                Text(L10n.napEditorMinutesLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(OAColor.textSecondary)

                Picker("", selection: $minutes) {
                    ForEach(minuteOptions, id: \.self) { value in
                        Text(String(format: "%02d", value))
                            .tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if hours == 0, minutes == 0 {
                minutes = 1
            }
        }
        .onChange(of: hours) { _, newHours in
            if newHours == 0, minutes == 0 {
                minutes = 1
            }
        }
    }
}

#Preview {
    NapEditorView(initialDraft: NapDraft(totalMinutes: 35, customSharedSettings: .featureDefaults))
        .environmentObject(AlarmStore())
}
