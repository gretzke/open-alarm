import SwiftUI

struct ShakeTaskDescriptor: TaskDescriptor {
    let typeID = "shake"
    let displayName = L10n.taskShakeName
    let systemImage = "figure.wave"
    let defaultTask: AlarmTask = .shake(intensity: 3)

    func matches(_ task: AlarmTask) -> Bool {
        if case .shake = task { return true }
        return false
    }

    func isVisibleInPicker(testingMode: Bool) -> Bool {
        true
    }

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
