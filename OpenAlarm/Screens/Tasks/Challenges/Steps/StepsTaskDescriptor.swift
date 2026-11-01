import SwiftUI

extension StepsTaskDescriptor {
    func makeTaskView(_ task: AlarmTask, mode: TaskMode, onEvent: @escaping (TaskEvent) -> Void) -> AnyView {
        guard case let .steps(count) = task else {
            preconditionFailure("StepsTaskDescriptor received a non-steps task")
        }

        return AnyView(StepsTaskView(count: count, mode: mode, onEvent: onEvent))
    }

    func makeConfigurator(_ task: Binding<AlarmTask>) -> AnyView {
        AnyView(StepsConfigurator(task: task))
    }
}
