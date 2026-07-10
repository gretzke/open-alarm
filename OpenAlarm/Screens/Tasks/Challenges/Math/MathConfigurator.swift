import SwiftUI

struct MathConfigurator: View {
    @Binding private var task: AlarmTask

    init(task: Binding<AlarmTask>) {
        _task = task
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OASpacing.xl) {
            ConfiguratorSlider(
                title: L10n.taskMathDifficultyTitle,
                value: difficultyIndex,
                in: 0...(MathDifficulty.allCases.count - 1),
                format: { L10n.taskMathLevelName(MathDifficulty.allCases[$0]) }
            )
            .padding(OASpacing.m)
            .oaGlassPanel()

            ConfiguratorStepper(
                title: L10n.taskMathCountTitle,
                value: count,
                in: 1...10
            )
            .padding(OASpacing.m)
            .oaGlassPanel()
        }
    }

    private var difficultyIndex: Binding<Int> {
        Binding(
            get: {
                MathDifficulty.allCases.firstIndex(of: difficulty) ?? 0
            },
            set: { index in
                let clampedIndex = min(max(index, 0), MathDifficulty.allCases.count - 1)
                task = .math(difficulty: MathDifficulty.allCases[clampedIndex], count: problemCount)
            }
        )
    }

    private var count: Binding<Int> {
        Binding(
            get: { problemCount },
            set: { newCount in
                task = .math(difficulty: difficulty, count: min(max(newCount, 1), 10))
            }
        )
    }

    private var difficulty: MathDifficulty {
        guard case let .math(difficulty, _) = task else {
            preconditionFailure("MathConfigurator received a non-math task")
        }
        return difficulty
    }

    private var problemCount: Int {
        guard case let .math(_, count) = task else {
            preconditionFailure("MathConfigurator received a non-math task")
        }
        return min(max(count, 1), 10)
    }
}
