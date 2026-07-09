import SwiftUI

struct DummySettingsView: View {
    var existingTask: AlarmTask?
    var onAdd: (AlarmTask) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text(String(localized: "task_dummy_description"))
                .font(.body)
                .foregroundStyle(OAColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onAdd(.dummy)
            } label: {
                Text(String(localized: existingTask == nil ? "task_add_button" : "task_save_button"))
                    .font(OAType.buttonLabel)
                    .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
            }
            .buttonStyle(.glassProminent)
            .tint(OAColor.actionCyan)

            Spacer()
        }
        .padding()
        .navigationTitle(String(localized: "task_dummy_name"))
    }
}
