import SwiftUI

struct ConfiguratorSlider: View {
    let title: LocalizedStringKey
    @Binding private var value: Int

    private let range: ClosedRange<Int>
    private let step: Int
    private let format: (Int) -> String

    init(
        title: LocalizedStringKey,
        value: Binding<Int>,
        in range: ClosedRange<Int>,
        step: Int = 1,
        format: @escaping (Int) -> String = { String($0) }
    ) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OASpacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: OASpacing.m) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(OAColor.textPrimary)

                Spacer(minLength: 0)

                Text(verbatim: format(value))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(OAColor.textSecondary)
            }

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
            .tint(OAColor.actionCyan)
        }
    }
}

struct ConfiguratorStepper: View {
    let title: LocalizedStringKey
    @Binding private var value: Int

    private let range: ClosedRange<Int>

    init(title: LocalizedStringKey, value: Binding<Int>, in range: ClosedRange<Int>) {
        self.title = title
        _value = value
        self.range = range
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OASpacing.m) {
            Text(title)
                .font(.headline)
                .foregroundStyle(OAColor.textPrimary)

            HStack(spacing: OASpacing.l) {
                Button {
                    setValue(value - 1)
                } label: {
                    Image(systemName: "minus")
                        .frame(minWidth: OASize.minTouchTarget, minHeight: OASize.minTouchTarget)
                }
                .buttonStyle(.glass)
                .disabled(value <= range.lowerBound)

                Text(verbatim: "\(value)")
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(OAColor.textPrimary)
                    .frame(minWidth: 64)

                Button {
                    setValue(value + 1)
                } label: {
                    Image(systemName: "plus")
                        .frame(minWidth: OASize.minTouchTarget, minHeight: OASize.minTouchTarget)
                }
                .buttonStyle(.glass)
                .disabled(value >= range.upperBound)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(verbatim: "\(value)"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    setValue(value + 1)
                case .decrement:
                    setValue(value - 1)
                @unknown default:
                    break
                }
            }
        }
    }

    private func setValue(_ candidate: Int) {
        let newValue = min(max(candidate, range.lowerBound), range.upperBound)
        guard newValue != value else {
            return
        }

        value = newValue
        Haptics.selection()
    }
}
