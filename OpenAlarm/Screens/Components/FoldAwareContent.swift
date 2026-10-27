import SwiftUI

struct FoldAwareContent<Content: View>: View {
    @ContentBuilder let content: Content

    var body: some View {
        if #available(iOS 27.1, *) {
            GeometryReader { geometry in
                let frame = FoldContentRegion.frame(
                    in: CGRect(origin: .zero, size: geometry.size),
                    divisions: geometry.reservedRegions(kind: .division).filter(\.isActive).map(\.frame),
                    occlusions: geometry.reservedRegions(kind: .occlusion).filter(\.isActive).map(\.frame)
                )
                content
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        } else {
            content
        }
    }
}
