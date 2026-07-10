import SwiftUI

struct DummyTaskView: View {
    var onCompleted: () -> Void

    var body: some View {
        VStack {
            Spacer()

            Text(String(localized: "task_dummy_instruction"))
                .font(OADawnType.display(28))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Spacer()

            Button {
                onCompleted()
            } label: {
                Text(String(localized: "task_dummy_button"))
                    .font(OADawnType.button)
                    .foregroundStyle(DawnPalette.inkDark)
                    .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
            }
            .background(Color.white, in: Capsule())
            .buttonStyle(.plain)

            Spacer()
        }
        .padding()
    }
}
