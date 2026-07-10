import SwiftUI

struct StepsConfigurator: View {
    @Binding private var task: AlarmTask

    init(task: Binding<AlarmTask>) {
        _task = task
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OASpacing.m) {
            ConfiguratorSlider(
                title: L10n.taskStepsCountTitle,
                value: goal,
                in: 10...100,
                step: 5,
                format: { String($0) }
            )
        }
        .padding(OASpacing.m)
        .oaGlassPanel()
    }

    private var goal: Binding<Int> {
        Binding(
            get: {
                guard case let .steps(count) = task else {
                    preconditionFailure("StepsConfigurator received a non-steps task")
                }
                let clampedCount = min(max(count, 10), 100)
                return Int((Double(clampedCount) / 5).rounded()) * 5
            },
            set: { newGoal in
                task = .steps(count: newGoal)
            }
        )
    }
}
