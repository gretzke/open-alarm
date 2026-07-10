import SwiftUI

struct MathConfigurator: View {
    @Binding private var task: AlarmTask

    init(task: Binding<AlarmTask>) {
        _task = task
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OASpacing.xl) {
            sliderSection(title: L10n.taskMathDifficultyTitle) {
                SteppedSlider(
                    value: difficultyIndex,
                    range: 0...(MathDifficulty.allCases.count - 1),
                    labels: MathDifficulty.allCases.map(L10n.taskMathLevelName)
                )
            }

            sliderSection(title: L10n.taskMathCountTitle) {
                SteppedSlider(value: count, range: 1...10)
            }
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

    private func sliderSection<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: OASpacing.m) {
            Text(title)
                .font(OAType.sectionLabel)
                .foregroundStyle(OAColor.textPrimary)

            content()
        }
        .padding(OASpacing.m)
        .oaGlassPanel()
    }
}
