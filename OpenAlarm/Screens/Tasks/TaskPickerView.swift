import SwiftUI
import UniformTypeIdentifiers

struct TaskPickerView: View {
    @Binding var tasks: [AlarmTask]
    private let maxTasks = 5

    @State private var showingTypeList = false
    @State private var editingIndex: Int?
    @State private var settingsTask: AlarmTask?
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
        .sheet(isPresented: $showingTypeList) {
            taskTypeListSheet
        }
        .sheet(item: $settingsTask) { task in
            NavigationStack {
                taskSettingsView(for: task)
            }
        }
    }

    private func filledTile(at index: Int) -> some View {
        let task = tasks[index]
        let info = TaskRegistry.typeInfo(for: task)
        return ZStack(alignment: .topTrailing) {
            Button {
                editingIndex = index
                settingsTask = task
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: info.systemImage)
                        .font(.title3)
                    Text(info.displayName)
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
            editingIndex = nil
            showingTypeList = true
        } label: {
            Image(systemName: "plus")
                .font(.title3)
                .frame(width: 56, height: 56)
                .oaGlassPanel()
        }
        .foregroundStyle(OAColor.actionCyan)
    }

    private func emptyTile() -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(OAColor.glassStroke.opacity(0.2))
            .frame(width: 56, height: 56)
    }

    private var taskTypeListSheet: some View {
        NavigationStack {
            List(TaskRegistry.availableTypes) { typeInfo in
                Button {
                    showingTypeList = false
                    // Short delay for sheet dismiss animation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        switch typeInfo.id {
                        case "dummy":
                            settingsTask = .dummy
                        case "math":
                            settingsTask = .math(difficulty: .simple, count: 3)
                        default:
                            break
                        }
                    }
                } label: {
                    Label(typeInfo.displayName, systemImage: typeInfo.systemImage)
                }
            }
            .navigationTitle(String(localized: "task_picker_choose_type"))
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func taskSettingsView(for task: AlarmTask) -> some View {
        let isEditing = editingIndex != nil
        switch task {
        case .dummy:
            DummySettingsView(existingTask: isEditing ? task : nil) { newTask in
                applyTask(newTask)
            }
        case .math:
            MathSettingsView(existingTask: isEditing ? task : nil) { newTask in
                applyTask(newTask)
            }
        }
    }

    private func applyTask(_ task: AlarmTask) {
        if let editIndex = editingIndex {
            tasks[editIndex] = task
        } else {
            tasks.append(task)
        }
        settingsTask = nil
        editingIndex = nil
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

extension AlarmTask: Identifiable {
    var id: String {
        switch self {
        case .dummy: "dummy"
        case .math(let d, let c): "math_\(d.rawValue)_\(c)"
        }
    }
}
