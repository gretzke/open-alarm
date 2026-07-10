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
                .padding(.horizontal, OASpacing.screenMargin)
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
                            startNap()
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.headline.weight(.bold))
                        }
                        .tint(OAColor.actionCyan)
                        .buttonStyle(.glassProminent)
                        .contentShape(Rectangle())
                        .accessibilityLabel(L10n.napEditorStartButton)
                    }
                }
            }
        }
        .background(Color.clear)
        .preferredColorScheme(.dark)
        .presentationBackground(.clear)
        .onAppear {
            if draft.useDefaultSharedSettings {
                draft.applyDefaultSharedSettings(alarmStore.resolvedNapDefaults)
            }
        }
    }

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.napEditorDurationTitle)
                .font(.headline)
                .foregroundStyle(OAColor.textSecondary)

            NapDurationPicker(hours: $draft.durationHours, minutes: $draft.durationMinutes, allowZeroMinutes: alarmStore.testingModeEnabled)
        }
    }

    private var useDefaultSharedSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { draft.useDefaultSharedSettings },
                set: { useDefault in
                    draft.useDefaultSharedSettings = useDefault
                    draft.applyDefaultSharedSettings(alarmStore.resolvedNapDefaults)
                }
            )) {
                Text(L10n.napEditorUseNapDefaultsToggle)
                    .font(.headline)
                    .foregroundStyle(OAColor.textPrimary)
            }
            .tint(OAColor.actionCyan)

            Text(L10n.napEditorUseNapDefaultsHint)
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
                Haptics.success()
                dismiss()
            } catch {
                errorMessage = alarmStore.userFacingErrorMessage(for: error)
            }
            isSaving = false
        }
    }
}

#Preview {
    NapEditorView(initialDraft: NapDraft(totalMinutes: 35, customSharedSettings: .featureDefaults))
        .environmentObject(AlarmStore())
}
