import SwiftUI

// MARK: - Task Registry

enum TaskRegistry {
    enum TaskTypeID {
        static let dummy = "dummy"
        static let math = "math"
    }

    struct TaskTypeInfo: Identifiable {
        let id: String
        let displayName: String
        let systemImage: String
    }

    static let dummyType = TaskTypeInfo(id: TaskTypeID.dummy, displayName: String(localized: "task_dummy_name"), systemImage: "hand.tap")
    static let mathType = TaskTypeInfo(id: TaskTypeID.math, displayName: String(localized: "task_math_name"), systemImage: "number")

    static let availableTypes: [TaskTypeInfo] = [
        dummyType,
        mathType,
    ]

    static func typeInfo(for task: AlarmTask) -> TaskTypeInfo {
        switch task {
        case .dummy:
            dummyType
        case .math:
            mathType
        }
    }

    static func defaultTask(for typeInfo: TaskTypeInfo) -> AlarmTask? {
        switch typeInfo.id {
        case TaskTypeID.dummy:
            .dummy
        case TaskTypeID.math:
            .math(difficulty: .simple, count: 3)
        default:
            nil
        }
    }
}
