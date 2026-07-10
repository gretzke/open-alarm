import SwiftUI

struct StepsTaskDescriptor: TaskDescriptor {
    let typeID = "steps"
    let displayName = L10n.taskStepsName
    let systemImage = "figure.walk"
    let defaultTask: AlarmTask = .steps(count: 30)

    func matches(_ task: AlarmTask) -> Bool {
        if case .steps = task { return true }
        return false
    }

    func isVisibleInPicker(testingMode: Bool) -> Bool {
        true
    }

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
