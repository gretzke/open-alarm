import SwiftUI
import UniformTypeIdentifiers

struct TaskPickerView: View {
    @Binding var tasks: [AlarmTask]
    @EnvironmentObject private var alarmStore: AlarmStore
    private let maxTasks = 5

    @State private var route: ConfiguratorRoute?
    @State private var draggingIndex: Int?

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
        .sheet(item: $route) { route in
            configuratorSheet(for: route)
        }
    }

    private func filledTile(at index: Int) -> some View {
        let task = tasks[index]
        let descriptor = TaskRegistry.descriptor(for: task)
        return ZStack(alignment: .topTrailing) {
            Button {
                route = .edit(index: index, task: task)
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

    @ViewBuilder
    private func configuratorSheet(for route: ConfiguratorRoute) -> some View {
        switch route {
        case .add:
            TaskTypeListContent(
                descriptors: TaskRegistry.pickerDescriptors(testingMode: alarmStore.testingModeEnabled),
                onSave: { task in
                    tasks.append(task)
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
            .presentationDetents([.large])
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

    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List(descriptors, id: \.typeID) { descriptor in
                Button {
                    path.append(descriptor.typeID)
                } label: {
                    Label(descriptor.displayName, systemImage: descriptor.systemImage)
                }
            }
            .navigationTitle(String(localized: "task_picker_choose_type"))
            .navigationDestination(for: String.self) { typeID in
                if let descriptor = TaskRegistry.descriptors.first(where: { $0.typeID == typeID }) {
                    TaskConfiguratorContent(initial: descriptor.defaultTask, onSave: onSave)
                }
            }
        }
        .presentationDetents([.large])
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
