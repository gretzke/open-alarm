import SwiftUI

extension MemoryTaskDescriptor {
    func makeTaskView(_ task: AlarmTask, mode: TaskMode, onEvent: @escaping (TaskEvent) -> Void) -> AnyView {
        guard case let .memory(difficulty, rounds) = task else {
            preconditionFailure("MemoryTaskDescriptor received a non-memory task")
        }

        return AnyView(MemoryTaskView(difficulty: difficulty, rounds: rounds, mode: mode, onEvent: onEvent))
    }

    func makeConfigurator(_ task: Binding<AlarmTask>) -> AnyView {
        AnyView(MemoryConfigurator(task: task))
    }
}
