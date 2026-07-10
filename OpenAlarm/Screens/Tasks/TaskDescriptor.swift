import SwiftUI

enum TaskMode: Equatable {
    case wake
    case preview
}

enum TaskEvent {
    case progress(Double)
    case completed
}

@MainActor
protocol TaskDescriptor {
    var typeID: String { get }
    var displayName: String { get }
    var systemImage: String { get }
    var defaultTask: AlarmTask { get }
    func matches(_ task: AlarmTask) -> Bool
    func isVisibleInPicker(testingMode: Bool) -> Bool
    func makeTaskView(_ task: AlarmTask, mode: TaskMode, onEvent: @escaping (TaskEvent) -> Void) -> AnyView
    func makeConfigurator(_ task: Binding<AlarmTask>) -> AnyView
}

struct DummyTaskDescriptor: TaskDescriptor {
    let typeID = "dummy"
    let displayName = String(localized: "task_dummy_name")
    let systemImage = "hand.tap"
    let defaultTask: AlarmTask = .dummy

    func matches(_ task: AlarmTask) -> Bool {
        if case .dummy = task { return true }
        return false
    }

    func isVisibleInPicker(testingMode: Bool) -> Bool {
        testingMode
    }

    func makeTaskView(_ task: AlarmTask, mode: TaskMode, onEvent: @escaping (TaskEvent) -> Void) -> AnyView {
        AnyView(DummyTaskView {
            onEvent(.completed)
        })
    }

    func makeConfigurator(_ task: Binding<AlarmTask>) -> AnyView {
        AnyView(DummySettingsView(existingTask: task.wrappedValue) { configuredTask in
            task.wrappedValue = configuredTask
        })
    }
}

struct MathTaskDescriptor: TaskDescriptor {
    let typeID = "math"
    let displayName = String(localized: "task_math_name")
    let systemImage = "number"
    let defaultTask: AlarmTask = .math(difficulty: .medium, count: 3)

    func matches(_ task: AlarmTask) -> Bool {
        if case .math = task { return true }
        return false
    }

    func isVisibleInPicker(testingMode: Bool) -> Bool {
        true
    }

    func makeTaskView(_ task: AlarmTask, mode: TaskMode, onEvent: @escaping (TaskEvent) -> Void) -> AnyView {
        guard case let .math(difficulty, count) = task else {
            preconditionFailure("MathTaskDescriptor received a non-math task")
        }

        return AnyView(MathTaskView(difficulty: difficulty, totalCount: count) {
            onEvent(.completed)
        })
    }

    func makeConfigurator(_ task: Binding<AlarmTask>) -> AnyView {
        AnyView(MathSettingsView(existingTask: task.wrappedValue) { configuredTask in
            task.wrappedValue = configuredTask
        })
    }
}
