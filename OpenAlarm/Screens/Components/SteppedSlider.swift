import SwiftUI

struct SteppedSlider: View {
    @Binding private var value: Int

    private let range: ClosedRange<Int>
    private let labels: [String]?

    init(value: Binding<Int>, range: ClosedRange<Int>, labels: [String]? = nil) {
        let detentCount = range.upperBound - range.lowerBound + 1
        precondition(labels == nil || labels!.count == detentCount, "labels must contain one entry per detent")

        _value = value
        self.range = range
        self.labels = labels
    }

    var body: some View {
        GeometryReader { geometry in
            let thumbDiameter = OASize.minTouchTarget
            let horizontalInset = thumbDiameter / 2
            let trackWidth = max(geometry.size.width - thumbDiameter, 1)
            let displayedValue = clamped(value)
            let thumbX = horizontalInset + position(for: displayedValue, width: trackWidth)
            let trackY: CGFloat = labels == nil ? thumbDiameter / 2 : 42

            ZStack {
                Capsule(style: .continuous)
                    .fill(OAColor.glassFill)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(OAColor.glassStroke.opacity(0.75), lineWidth: 0.8)
                    )
                    .frame(width: trackWidth, height: OASpacing.s)
                    .position(x: geometry.size.width / 2, y: trackY)

                Capsule(style: .continuous)
                    .fill(OAColor.actionCyan)
                    .frame(width: position(for: displayedValue, width: trackWidth), height: OASpacing.s)
                    .position(
                        x: horizontalInset + position(for: displayedValue, width: trackWidth) / 2,
                        y: trackY
                    )

                ForEach(Array(range), id: \.self) { detent in
                    Circle()
                        .fill(detent <= displayedValue ? OAColor.background : OAColor.textSecondary)
                        .frame(width: OASpacing.s, height: OASpacing.s)
                        .overlay(Circle().stroke(OAColor.glassStroke, lineWidth: 0.8))
                        .position(
                            x: horizontalInset + position(for: detent, width: trackWidth),
                            y: trackY
                        )
                }

                if let label = label(for: displayedValue) {
                    Text(label)
                        .font(OAType.metaEmphasis)
                        .foregroundStyle(OAColor.textPrimary)
                        .lineLimit(1)
                        .position(x: thumbX, y: 10)
                }

                Circle()
                    .fill(OAColor.background.opacity(0.55))
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .overlay(Circle().stroke(OAColor.glassStroke.opacity(0.9), lineWidth: 1))
                    .position(x: thumbX, y: trackY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        updateValue(for: gesture.location.x, trackWidth: trackWidth, horizontalInset: horizontalInset)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(label(for: displayedValue) ?? "")
            .accessibilityValue("\(displayedValue)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    setValue(clamped(displayedValue + 1))
                case .decrement:
                    setValue(clamped(displayedValue - 1))
                @unknown default:
                    break
                }
            }
        }
        .frame(height: labels == nil ? OASize.minTouchTarget : 64)
    }

    private var detentCount: Int {
        range.upperBound - range.lowerBound + 1
    }

    private func clamped(_ candidate: Int) -> Int {
        min(max(candidate, range.lowerBound), range.upperBound)
    }

    private func label(for value: Int) -> String? {
        guard let labels else {
            return nil
        }
        return labels[clamped(value) - range.lowerBound]
    }

    private func position(for value: Int, width: CGFloat) -> CGFloat {
        guard detentCount > 1 else {
            return 0
        }
        return CGFloat(clamped(value) - range.lowerBound) / CGFloat(detentCount - 1) * width
    }

    private func updateValue(for location: CGFloat, trackWidth: CGFloat, horizontalInset: CGFloat) {
        guard detentCount > 1 else {
            setValue(range.lowerBound)
            return
        }

        let normalizedPosition = min(max((location - horizontalInset) / trackWidth, 0), 1)
        let detent = range.lowerBound + Int((normalizedPosition * CGFloat(detentCount - 1)).rounded())
        setValue(detent)
    }

    private func setValue(_ newValue: Int) {
        guard newValue != value else {
            return
        }
        value = newValue
        Haptics.selection()
    }
}

#Preview {
    @Previewable @State var difficulty = 2

    SteppedSlider(
        value: $difficulty,
        range: 0...4,
        labels: ["1", "2", "3", "4", "5"]
    )
    .padding(OASpacing.screenMargin)
    .background(OAColor.background)
}
