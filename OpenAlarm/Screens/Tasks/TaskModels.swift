import SwiftUI

// MARK: - Task Registry

@MainActor
enum TaskRegistry {
    private static let dummyDescriptor = DummyTaskDescriptor()
    private static let mathDescriptor = MathTaskDescriptor()
    private static let shakeDescriptor = ShakeTaskDescriptor()
    private static let memoryDescriptor = MemoryTaskDescriptor()
    private static let stepsDescriptor = StepsTaskDescriptor()

    static let descriptors: [any TaskDescriptor] = [
        dummyDescriptor,
        mathDescriptor,
        shakeDescriptor,
        memoryDescriptor,
        stepsDescriptor,
    ]

    /// The runtime lookup intentionally does not apply picker-visibility rules.
    /// Persisted dummy tasks must continue to run outside testing mode.
    static func descriptor(for task: AlarmTask) -> any TaskDescriptor {
        switch task {
        case .dummy:
            dummyDescriptor
        case .math:
            mathDescriptor
        case .shake:
            shakeDescriptor
        case .memory:
            memoryDescriptor
        case .steps:
            stepsDescriptor
        }
    }

    static func pickerDescriptors(testingMode: Bool) -> [any TaskDescriptor] {
        descriptors.filter { $0.isVisibleInPicker(testingMode: testingMode) }
    }
}
