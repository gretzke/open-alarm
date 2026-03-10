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
                Text(String(localized: "task_add_button"))
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.glassProminent)
            .tint(OAColor.actionCyan)

            Spacer()
        }
        .padding()
        .navigationTitle(String(localized: "task_dummy_name"))
    }
}
