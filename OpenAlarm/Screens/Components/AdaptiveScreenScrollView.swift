import SwiftUI

/// Keeps short outer displays and large text scrollable without stretching on the inner display.
struct AdaptiveScreenScrollView<Content: View>: View {
    @ContentBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(maxWidth: 600)
                    .frame(minHeight: geometry.size.height)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
