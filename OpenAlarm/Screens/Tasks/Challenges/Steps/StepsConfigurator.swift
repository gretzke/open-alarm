import SwiftUI

struct StepsConfigurator: View {
    private static let goals = [10, 20, 30, 50, 75, 100]

    @Binding private var task: AlarmTask

    init(task: Binding<AlarmTask>) {
        _task = task
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OASpacing.m) {
            Text(L10n.taskStepsCountTitle)
                .font(OAType.sectionLabel)
                .foregroundStyle(OAColor.textPrimary)

            SteppedSlider(
                value: goalIndex,
                range: 0...5,
                labels: Self.goals.map { String($0) }
            )
        }
        .padding(OASpacing.m)
        .oaGlassPanel()
    }

    private var goalIndex: Binding<Int> {
        Binding(
            get: {
                guard case let .steps(count) = task else {
                    preconditionFailure("StepsConfigurator received a non-steps task")
                }
                let clampedCount = min(max(count, 10), 100)
                return Self.goals.indices.min {
                    abs(Self.goals[$0] - clampedCount) < abs(Self.goals[$1] - clampedCount)
                } ?? 2
            },
            set: { newIndex in
                let index = min(max(newIndex, 0), Self.goals.count - 1)
                task = .steps(count: Self.goals[index])
            }
        )
    }
}
