import SwiftUI

/// Scrolls the content and keeps the actions below it, so short panes
/// (outer landscape, tabletop) always show the primary action.
struct PinnedActionsScrollView<Content: View, Actions: View>: View {
    var margin: CGFloat = OASpacing.onboardingMargin
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        // A plain stack, not a safe-area inset: the scroll view ends above the
        // actions, so scrolled content never shows through behind them.
        VStack(spacing: 0) {
            AdaptiveScreenScrollView {
                // The centering frame re-proposes the content's own ideal height.
                // A VStack with several multiline texts can split that height so
                // that one text gets less than it needs and truncates (the
                // "Allow alarm schedul..." title in outer portrait). Scrolled
                // content never needs compressing, so it keeps its ideal height.
                // The stacks keep the modifiers on one view when a caller passes several.
                VStack(spacing: 24) { content }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(margin)
            }

            VStack(spacing: 12) { actions }
                // Keeps a gap when the scrolled content runs up to the actions.
                .padding(.top, 12)
                .padding(.horizontal, margin)
                .padding(.bottom, margin)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
        }
    }
}
