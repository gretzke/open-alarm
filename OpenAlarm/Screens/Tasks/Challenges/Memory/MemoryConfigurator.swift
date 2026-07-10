import SwiftUI

struct MemoryConfigurator: View {
    @Binding private var task: AlarmTask

    init(task: Binding<AlarmTask>) {
        _task = task
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OASpacing.xl) {
            ConfiguratorSlider(
                title: L10n.taskMemoryDifficultyTitle,
                value: difficulty,
                in: 1...5,
                format: memoryLevelName
            )
            .padding(OASpacing.m)
            .oaGlassPanel()

            ConfiguratorStepper(
                title: L10n.taskMemoryRoundsTitle,
                value: rounds,
                in: 1...5
            )
            .padding(OASpacing.m)
            .oaGlassPanel()
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

    private func memoryLevelName(_ difficulty: Int) -> String {
        switch difficulty {
        case 1: L10n.taskMemoryLevel1
        case 2: L10n.taskMemoryLevel2
        case 3: L10n.taskMemoryLevel3
        case 4: L10n.taskMemoryLevel4
        default: L10n.taskMemoryLevel5
        }
    }
}
