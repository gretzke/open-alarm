import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text(L10n.helloWorldTitle)
                .font(.largeTitle.bold())

            Text(L10n.helloWorldSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
