import SwiftUI

struct MemoryConfigurator: View {
    @Binding private var task: AlarmTask

    init(task: Binding<AlarmTask>) {
        _task = task
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OASpacing.xl) {
            sliderSection(title: L10n.taskMemoryDifficultyTitle) {
                SteppedSlider(
                    value: difficulty,
                    range: 1...5,
                    labels: [
                        L10n.taskMemoryLevel1,
                        L10n.taskMemoryLevel2,
                        L10n.taskMemoryLevel3,
                        L10n.taskMemoryLevel4,
                        L10n.taskMemoryLevel5
                    ]
                )
            }

            sliderSection(title: L10n.taskMemoryRoundsTitle) {
                SteppedSlider(value: rounds, range: 1...5)
            }
        }
        .padding(OASpacing.m)
        .oaGlassPanel()
    }

    @ViewBuilder
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
    }

    private var difficulty: Binding<Int> {
        Binding(
            get: {
                guard case let .memory(difficulty, _) = task else {
                    preconditionFailure("MemoryConfigurator received a non-memory task")
                }
                return min(max(difficulty, 1), 5)
            },
            set: { newDifficulty in
                guard case let .memory(_, rounds) = task else {
                    preconditionFailure("MemoryConfigurator received a non-memory task")
                }
                task = .memory(difficulty: min(max(newDifficulty, 1), 5), rounds: min(max(rounds, 1), 5))
            }
        )
    }

    private var rounds: Binding<Int> {
        Binding(
            get: {
                guard case let .memory(_, rounds) = task else {
                    preconditionFailure("MemoryConfigurator received a non-memory task")
                }
                return min(max(rounds, 1), 5)
            },
            set: { newRounds in
                guard case let .memory(difficulty, _) = task else {
                    preconditionFailure("MemoryConfigurator received a non-memory task")
                }
                task = .memory(difficulty: min(max(difficulty, 1), 5), rounds: min(max(newRounds, 1), 5))
            }
        )
    }
}
