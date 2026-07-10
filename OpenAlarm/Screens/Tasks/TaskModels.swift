import SwiftUI

// MARK: - Task Registry

@MainActor
enum TaskRegistry {
    private static let dummyDescriptor = DummyTaskDescriptor()
    private static let mathDescriptor = MathTaskDescriptor()
    private static let shakeDescriptor = ShakeTaskDescriptor()
    private static let memoryDescriptor = MemoryTaskDescriptor()
    private static let stepsDescriptor = StepsTaskDescriptor()
    private static let scanDescriptor = ScanTaskDescriptor()

    static let descriptors: [any TaskDescriptor] = [
        dummyDescriptor,
        mathDescriptor,
        shakeDescriptor,
        memoryDescriptor,
        stepsDescriptor,
        scanDescriptor,
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
        case .scanObject:
            scanDescriptor
        }
    }

    static func pickerDescriptors(testingMode: Bool) -> [any TaskDescriptor] {
        descriptors.filter { $0.isVisibleInPicker(testingMode: testingMode) }
    }
}
