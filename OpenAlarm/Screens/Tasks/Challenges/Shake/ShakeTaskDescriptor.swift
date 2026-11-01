import SwiftUI

extension ShakeTaskDescriptor {
    func makeTaskView(_ task: AlarmTask, mode: TaskMode, onEvent: @escaping (TaskEvent) -> Void) -> AnyView {
        guard case let .shake(intensity) = task else {
            preconditionFailure("ShakeTaskDescriptor received a non-shake task")
        }

        return AnyView(ShakeTaskView(intensity: intensity, mode: mode, onEvent: onEvent))
    }

    func makeConfigurator(_ task: Binding<AlarmTask>) -> AnyView {
        AnyView(ShakeConfigurator(task: task))
    }
}
