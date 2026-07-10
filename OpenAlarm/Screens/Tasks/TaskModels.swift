import SwiftUI

// MARK: - Task Registry

@MainActor
enum TaskRegistry {
    private static let dummyDescriptor = DummyTaskDescriptor()
    private static let mathDescriptor = MathTaskDescriptor()

    static let descriptors: [any TaskDescriptor] = [
        dummyDescriptor,
        mathDescriptor,
    ]

    /// The runtime lookup intentionally does not apply picker-visibility rules.
    /// Persisted dummy tasks must continue to run outside testing mode.
    static func descriptor(for task: AlarmTask) -> any TaskDescriptor {
        switch task {
        case .dummy:
            dummyDescriptor
        case .math:
            mathDescriptor
        }
    }

    static func pickerDescriptors(testingMode: Bool) -> [any TaskDescriptor] {
        descriptors.filter { $0.isVisibleInPicker(testingMode: testingMode) }
    }
}
