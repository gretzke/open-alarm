import SwiftUI

// MARK: - Task Registry

enum TaskRegistry {
    struct TaskTypeInfo: Identifiable {
        let id: String
        let displayName: String
        let systemImage: String
    }

    static let availableTypes: [TaskTypeInfo] = [
        TaskTypeInfo(id: "dummy", displayName: String(localized: "task_dummy_name"), systemImage: "hand.tap"),
        TaskTypeInfo(id: "math", displayName: String(localized: "task_math_name"), systemImage: "number"),
    ]

    static func typeInfo(for task: AlarmTask) -> TaskTypeInfo {
        switch task {
        case .dummy:
            availableTypes.first { $0.id == "dummy" }!
        case .math:
            availableTypes.first { $0.id == "math" }!
        }
    }
}
