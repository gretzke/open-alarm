import SwiftUI

struct ScanTaskDescriptor: TaskDescriptor {
    let typeID = "scanObject"
    let displayName = L10n.taskScanName
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

    func makeTaskView(_ task: AlarmTask, mode: TaskMode, onEvent: @escaping (TaskEvent) -> Void) -> AnyView {
        guard case let .scanObject(objectClass) = task else {
            preconditionFailure("ScanTaskDescriptor received a non-scan task")
        }

        return AnyView(ScanTaskView(objectClass: objectClass, mode: mode, onEvent: onEvent))
    }

    func makeConfigurator(_ task: Binding<AlarmTask>) -> AnyView {
        AnyView(ScanConfigurator(task: task))
    }
}
