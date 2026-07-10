import SwiftUI
import UniformTypeIdentifiers

struct TaskPickerView: View {
    @Binding var tasks: [AlarmTask]
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var alarmStore: AlarmStore
    private let maxTasks = 5

    @State private var route: ConfiguratorRoute?
    @State private var draggingIndex: Int?
    @State private var permissionFlowStep: TaskPermissionFlowStep?
    @State private var pendingPermission: TaskPermission?
    @State private var pendingRoute: ConfiguratorRoute?
    @State private var openRouteAfterPermissionCoverDismisses = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "task_picker_title"))
                .font(.headline)
                .foregroundStyle(OAColor.textPrimary)

            HStack(spacing: 8) {
                ForEach(0..<maxTasks, id: \.self) { index in
                    if index < tasks.count {
                        filledTile(at: index)
                    } else if index == tasks.count {
                        addTile()
                    } else {
                        emptyTile()
                    }
                }
            }
        }
        .fullScreenCover(item: $route) { route in
            configuratorSheet(for: route)
        }
        .fullScreenCover(
            item: $permissionFlowStep,
            onDismiss: handlePermissionCoverDismissed
        ) { step in
            switch step {
            case .prePrompt:
                TaskPermissionPrePromptView(
                    permission: pendingPermission ?? .camera,
                    onRequestPermission: requestPermission,
                    onCancel: cancelPermissionFlow
                )
            case .denied:
                TaskPermissionDeniedView(
                    permission: pendingPermission ?? .camera,
                    onOpenSettings: alarmStore.openSettings,
                    onCancel: cancelPermissionFlow
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            handlePermissionAuthorizationChange(phase)
        }
    }

    private func filledTile(at index: Int) -> some View {
        let task = tasks[index]
        let descriptor = TaskRegistry.descriptor(for: task)
        return ZStack(alignment: .topTrailing) {
            Button {
                requestRoute(.edit(index: index, task: task), for: descriptor)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: descriptor.systemImage)
                        .font(.title3)
                    Text(descriptor.displayName)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .frame(width: 56, height: 56)
                .oaGlassPanel()
            }
            .foregroundStyle(OAColor.textPrimary)

            Button {
                withAnimation { _ = tasks.remove(at: index) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(OAColor.danger)
            }
            .offset(x: 4, y: -4)
        }
        .onDrag {
            draggingIndex = index
            return NSItemProvider(object: "\(index)" as NSString)
        }
        .onDrop(of: [.text], delegate: TaskDropDelegate(
            targetIndex: index,
            draggingIndex: $draggingIndex,
            tasks: $tasks
        ))
    }

    private func addTile() -> some View {
        Button {
            route = .add
        } label: {
            Image(systemName: "plus")
                .font(.title3)
                .frame(width: 56, height: 56)
                .oaGlassPanel()
        }
        .foregroundStyle(OAColor.actionCyan)
    }

    private func emptyTile() -> some View {
        RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous)
            .fill(OAColor.glassStroke.opacity(0.2))
            .frame(width: 56, height: 56)
    }

    private func requestRoute(_ requestedRoute: ConfiguratorRoute, for descriptor: any TaskDescriptor) {
        guard let permission = descriptor.requiredPermission else {
            route = requestedRoute
            return
        }

        pendingPermission = permission
        pendingRoute = requestedRoute
        switch TaskPermissionAuthorizer.status(for: permission) {
        case .authorized:
            route = requestedRoute
            pendingPermission = nil
            pendingRoute = nil
        case .notDetermined:
            permissionFlowStep = .prePrompt
        case .denied:
            permissionFlowStep = .denied
        }
    }

    private func requestPermission() {
        guard let pendingPermission else { return }
        TaskPermissionAuthorizer.request(pendingPermission) { granted in
            if granted {
                openRouteAfterPermissionCoverDismisses = true
                permissionFlowStep = nil
            } else {
                // Keep the pending route: granting later in Settings reopens it.
                permissionFlowStep = .denied
            }
        }
    }

    private func cancelPermissionFlow() {
        permissionFlowStep = nil
        pendingPermission = nil
        pendingRoute = nil
        openRouteAfterPermissionCoverDismisses = false
    }

    private func handlePermissionAuthorizationChange(_ phase: ScenePhase) {
        guard phase == .active,
              permissionFlowStep == .denied,
              let pendingPermission,
              TaskPermissionAuthorizer.status(for: pendingPermission) == .authorized else {
            return
        }

        openRouteAfterPermissionCoverDismisses = true
        permissionFlowStep = nil
    }

    private func handlePermissionCoverDismissed() {
        guard openRouteAfterPermissionCoverDismisses,
              let pendingRoute else {
            return
        }

        openRouteAfterPermissionCoverDismisses = false
        pendingPermission = nil
        self.pendingRoute = nil
        route = pendingRoute
    }

    @ViewBuilder
    private func configuratorSheet(for route: ConfiguratorRoute) -> some View {
        switch route {
        case .add:
            TaskTypeListContent(
                descriptors: TaskRegistry.pickerDescriptors(testingMode: alarmStore.testingModeEnabled),
                onSave: { task in
                    tasks.append(task)
                    self.route = nil
                },
                onCancel: {
                    self.route = nil
                }
            )
        case .edit(_, let task):
            NavigationStack {
                TaskConfiguratorContent(
                    initial: task,
                    onSave: { updatedTask in
                        guard case .edit(let index, _) = self.route,
                              tasks.indices.contains(index) else {
                            return
                        }
                        tasks[index] = updatedTask
                        self.route = nil
                    },
                    onCancel: {
                        self.route = nil
                    }
                )
            }
        }
    }
}

private enum ConfiguratorRoute: Identifiable, Equatable {
    case add
    case edit(index: Int, task: AlarmTask)

    var id: String {
        switch self {
        case .add:
            "add"
        case .edit(let index, _):
            "edit-\(index)"
        }
    }
}

private struct TaskTypeListContent: View {
    let descriptors: [any TaskDescriptor]
    let onSave: (AlarmTask) -> Void
    let onCancel: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var alarmStore: AlarmStore
    @State private var path: [String] = []
    @State private var permissionFlowStep: TaskPermissionFlowStep?
    @State private var pendingPermission: TaskPermission?
    @State private var pendingTypeID: String?
    @State private var openTypeAfterPermissionCoverDismisses = false

    var body: some View {
        NavigationStack(path: $path) {
            List(descriptors, id: \.typeID) { descriptor in
                Button {
                    selectDescriptor(descriptor)
                } label: {
                    Label(descriptor.displayName, systemImage: descriptor.systemImage)
                }
            }
            .navigationTitle(String(localized: "task_picker_choose_type"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel, action: onCancel)
                }
            }
            .navigationDestination(for: String.self) { typeID in
                if let descriptor = TaskRegistry.descriptors.first(where: { $0.typeID == typeID }) {
                    TaskConfiguratorContent(
                        initial: descriptor.defaultTask,
                        onSave: onSave,
                        onCancel: {
                            guard !path.isEmpty else { return }
                            path.removeLast()
                        },
                        cancelLabel: L10n.actionBack
                    )
                }
            }
        }
        .fullScreenCover(
            item: $permissionFlowStep,
            onDismiss: handlePermissionCoverDismissed
        ) { step in
            switch step {
            case .prePrompt:
                TaskPermissionPrePromptView(
                    permission: pendingPermission ?? .camera,
                    onRequestPermission: requestPermission,
                    onCancel: cancelPermissionFlow
                )
            case .denied:
                TaskPermissionDeniedView(
                    permission: pendingPermission ?? .camera,
                    onOpenSettings: alarmStore.openSettings,
                    onCancel: cancelPermissionFlow
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            handlePermissionAuthorizationChange(phase)
        }
    }

    private func selectDescriptor(_ descriptor: any TaskDescriptor) {
        guard let permission = descriptor.requiredPermission else {
            path.append(descriptor.typeID)
            return
        }

        pendingPermission = permission
        pendingTypeID = descriptor.typeID
        switch TaskPermissionAuthorizer.status(for: permission) {
        case .authorized:
            path.append(descriptor.typeID)
            pendingPermission = nil
            pendingTypeID = nil
        case .notDetermined:
            permissionFlowStep = .prePrompt
        case .denied:
            permissionFlowStep = .denied
        }
    }

    private func requestPermission() {
        guard let pendingPermission else { return }
        TaskPermissionAuthorizer.request(pendingPermission) { granted in
            if granted {
                openTypeAfterPermissionCoverDismisses = true
                permissionFlowStep = nil
            } else {
                // Keep the pending type: granting later in Settings reopens it.
                permissionFlowStep = .denied
            }
        }
    }

    private func cancelPermissionFlow() {
        permissionFlowStep = nil
        pendingPermission = nil
        pendingTypeID = nil
        openTypeAfterPermissionCoverDismisses = false
    }

    private func handlePermissionAuthorizationChange(_ phase: ScenePhase) {
        guard phase == .active,
              permissionFlowStep == .denied,
              let pendingPermission,
              TaskPermissionAuthorizer.status(for: pendingPermission) == .authorized else {
            return
        }

        openTypeAfterPermissionCoverDismisses = true
        permissionFlowStep = nil
    }

    private func handlePermissionCoverDismissed() {
        guard openTypeAfterPermissionCoverDismisses,
              let pendingTypeID else {
            return
        }

        openTypeAfterPermissionCoverDismisses = false
        pendingPermission = nil
        self.pendingTypeID = nil
        path.append(pendingTypeID)
    }
}

private struct TaskDropDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var draggingIndex: Int?
    @Binding var tasks: [AlarmTask]

    func dropEntered(info: DropInfo) {
        guard let from = draggingIndex, from != targetIndex else { return }
        withAnimation {
            tasks.swapAt(from, targetIndex)
        }
        draggingIndex = targetIndex
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingIndex = nil
        return true
    }
}
