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
                    .font(OAType.buttonLabel)
                    .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
            }
            .buttonStyle(.glassProminent)
            .tint(OAColor.actionCyan)

            Spacer()
        }
        .padding()
    }
}
