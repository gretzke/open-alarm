import SwiftUI

extension DummyTaskDescriptor {
    func makeTaskView(_ task: AlarmTask, mode: TaskMode, onEvent: @escaping (TaskEvent) -> Void) -> AnyView {
        AnyView(DummyTaskView {
            onEvent(.completed)
        })
    }

    func makeConfigurator(_ task: Binding<AlarmTask>) -> AnyView {
        AnyView(DummyConfigurator())
    }
}

extension MathTaskDescriptor {
    func makeTaskView(_ task: AlarmTask, mode: TaskMode, onEvent: @escaping (TaskEvent) -> Void) -> AnyView {
        guard case let .math(difficulty, count) = task else {
            preconditionFailure("MathTaskDescriptor received a non-math task")
        }

        return AnyView(
            MathTaskView(
                difficulty: difficulty,
                totalCount: count,
                mode: mode,
                onEvent: onEvent
            )
        )
    }

    func makeConfigurator(_ task: Binding<AlarmTask>) -> AnyView {
        AnyView(MathConfigurator(task: task))
    }
}
