import Foundation
#if canImport(UIKit)
import SwiftUI
#endif

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
    var requiredPermission: TaskPermission? { get }
    func matches(_ task: AlarmTask) -> Bool
    func isVisibleInPicker(testingMode: Bool) -> Bool
#if canImport(UIKit)
    func makeTaskView(_ task: AlarmTask, mode: TaskMode, onEvent: @escaping (TaskEvent) -> Void) -> AnyView
    func makeConfigurator(_ task: Binding<AlarmTask>) -> AnyView
#endif
}

extension TaskDescriptor {
    var requiredPermission: TaskPermission? { nil }
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
}

struct ShakeTaskDescriptor: TaskDescriptor {
    let typeID = "shake"
    let displayName = String(localized: "task_shake_name")
    let systemImage = "figure.wave"
    let defaultTask: AlarmTask = .shake(intensity: 3)

    func matches(_ task: AlarmTask) -> Bool {
        if case .shake = task { return true }
        return false
    }

    func isVisibleInPicker(testingMode: Bool) -> Bool {
        true
    }
}

struct MemoryTaskDescriptor: TaskDescriptor {
    let typeID = "memory"
    let displayName = String(localized: "task_memory_name")
    let systemImage = "square.grid.3x3.fill"
    let defaultTask: AlarmTask = .memory(difficulty: 1, rounds: 3)

    func matches(_ task: AlarmTask) -> Bool {
        if case .memory = task { return true }
        return false
    }

    func isVisibleInPicker(testingMode: Bool) -> Bool {
        true
    }
}

struct StepsTaskDescriptor: TaskDescriptor {
    let typeID = "steps"
    let displayName = String(localized: "task_steps_name")
    let systemImage = "figure.walk"
    let defaultTask: AlarmTask = .steps(count: 30)
    let requiredPermission: TaskPermission? = .motion

    func matches(_ task: AlarmTask) -> Bool {
        if case .steps = task { return true }
        return false
    }

    func isVisibleInPicker(testingMode: Bool) -> Bool {
        true
    }
}

struct ScanTaskDescriptor: TaskDescriptor {
    let typeID = "scanObject"
    let displayName = String(localized: "task_scan_name")
    let systemImage = "viewfinder"
    let defaultTask: AlarmTask = .scanObject(objectClass: "mug")
    let requiredPermission: TaskPermission? = .camera

    func matches(_ task: AlarmTask) -> Bool {
        if case .scanObject = task { return true }
        return false
    }

    func isVisibleInPicker(testingMode: Bool) -> Bool {
        true
    }
}
