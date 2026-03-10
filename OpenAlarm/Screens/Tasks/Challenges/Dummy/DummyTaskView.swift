import SwiftUI

struct DummyTaskView: View {
    var onCompleted: () -> Void

    var body: some View {
        VStack {
            Spacer()

            Text(String(localized: "task_dummy_instruction"))
                .font(.title2)
                .foregroundStyle(OAColor.textPrimary)
                .multilineTextAlignment(.center)

            Spacer()

            Button {
                onCompleted()
            } label: {
                Text(String(localized: "task_dummy_button"))
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.glassProminent)
            .tint(OAColor.actionCyan)

            Spacer()
        }
        .padding()
    }
}
