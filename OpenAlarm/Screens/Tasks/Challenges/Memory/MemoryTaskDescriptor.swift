import SwiftUI

struct MemoryTaskDescriptor: TaskDescriptor {
    let typeID = "memory"
    let displayName = L10n.taskMemoryName
    let systemImage = "square.grid.3x3.fill"
    let defaultTask: AlarmTask = .memory(difficulty: 1, rounds: 3)

    func matches(_ task: AlarmTask) -> Bool {
        if case .memory = task { return true }
        return false
    }

    func isVisibleInPicker(testingMode: Bool) -> Bool {
        true
    }

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
