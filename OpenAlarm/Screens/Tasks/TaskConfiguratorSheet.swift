import SwiftUI

struct TaskConfiguratorContent: View {
    let onSave: (AlarmTask) -> Void
    let onCancel: (() -> Void)?
    let cancelLabel: LocalizedStringKey

    @State private var draft: AlarmTask
    @State private var previewProgress = 0.3
    @State private var previewGeneration = 0
    @State private var previewResetTask: Task<Void, Never>?
    @State private var isShowingPreviewSuccess = false
    @State private var isShowingSettings = true
    @State private var settingsDetent: PresentationDetent = .fraction(0.44)
    @State private var pendingExit: PendingConfiguratorExit?

    init(
        initial: AlarmTask,
        onSave: @escaping (AlarmTask) -> Void,
        onCancel: (() -> Void)? = nil,
        cancelLabel: LocalizedStringKey = L10n.actionCancel
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        self.cancelLabel = cancelLabel
        _draft = State(initialValue: initial)
    }

    var body: some View {
        preview
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(
                isPresented: $isShowingSettings,
                onDismiss: handleSettingsDismissed
            ) {
                settingsSheet
            }
            .onChange(of: previewConfiguration) { _, _ in
                previewResetTask?.cancel()
                previewResetTask = nil
                previewProgress = 0.3
                isShowingPreviewSuccess = false
            }
            .onDisappear {
                previewResetTask?.cancel()
            }
    }

    private var settingsSheet: some View {
        NavigationStack {
            ScrollView {
                TaskRegistry.descriptor(for: draft)
                    .makeConfigurator($draft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(OASpacing.screenMargin)
            }
            .background(Color.clear)
            .navigationTitle(L10n.taskConfiguratorTitle)
            .navigationBarTitleDisplayMode(.inline)
            // Same toolbar treatment as AlarmEditorView: system chrome for the
            // leading close button, prominent cyan glass for confirm.
            .toolbar {
                if onCancel != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: requestCancel) {
                            Image(systemName: "xmark")
                                .font(OAType.buttonLabel)
                        }
                        .tint(OAColor.textPrimary)
                        .accessibilityLabel(cancelLabel)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: attemptSave) {
                        Image(systemName: "checkmark")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(DawnPalette.inkDark)
                    }
                    // White-on-dawn like the other buttons on dawn surfaces;
                    // action cyan clashes with the bright gradient behind the sheet.
                    .tint(.white)
                    .buttonStyle(.glassProminent)
                    .contentShape(Rectangle())
                    .accessibilityLabel(L10n.taskConfiguratorSave)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .background(Color.clear)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color.clear
                .glassEffect(.regular, in: Rectangle())
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .presentationDetents([.fraction(0.28), .fraction(0.44), .large], selection: $settingsDetent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .presentationBackground(.clear)
        .presentationBackgroundInteraction(.enabled)
        .interactiveDismissDisabled()
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                DawnBackground(progress: previewProgress)

                ZStack {
                    previewTaskView
                        .id(PreviewIdentity(configuration: previewConfiguration, generation: previewGeneration))

                    if isShowingPreviewSuccess {
                        TaskSuccessOverlay()
                    }
                }
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height * 0.5,
                    alignment: .top
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isShowingPreviewSuccess)
    }

    @ViewBuilder
    private var previewTaskView: some View {
        switch draft {
        case let .math(difficulty, count):
            MathTaskView(
                difficulty: difficulty,
                totalCount: count,
                mode: .preview,
                onEvent: handlePreviewEvent
            )
        case let .memory(difficulty, rounds):
            MemoryTaskView(
                difficulty: difficulty,
                rounds: rounds,
                mode: .preview,
                onEvent: handlePreviewEvent
            )
        default:
            TaskRegistry.descriptor(for: draft)
                .makeTaskView(draft, mode: .preview, onEvent: handlePreviewEvent)
        }
    }

    private func handlePreviewEvent(_ event: TaskEvent) {
        switch event {
        case .progress(let progress):
            guard !isShowingPreviewSuccess else { return }
            previewProgress = 0.3 + min(max(progress, 0), 1) * 0.4
        case .completed:
            guard !isShowingPreviewSuccess else {
                return
            }
            Haptics.success()
            withAnimation(.easeInOut(duration: 0.2)) {
                previewProgress = min(previewProgress + 0.15, 1)
                isShowingPreviewSuccess = true
            }
            schedulePreviewReset()
        }
    }

    private func schedulePreviewReset() {
        previewResetTask?.cancel()
        let completedConfiguration = previewConfiguration
        previewResetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: TaskSuccessPresentation.duration)
            } catch {
                return
            }

            guard !Task.isCancelled, previewConfiguration == completedConfiguration else {
                return
            }

            isShowingPreviewSuccess = false
            previewProgress = 0.3
            previewGeneration &+= 1
            previewResetTask = nil
        }
    }

    private var previewConfiguration: PreviewTaskConfiguration {
        PreviewTaskConfiguration(task: draft)
    }

    private func attemptSave() {
        requestSave(draft)
    }

    private func requestCancel() {
        guard onCancel != nil else { return }
        pendingExit = .cancel
        isShowingSettings = false
    }

    private func requestSave(_ task: AlarmTask) {
        pendingExit = .save(task)
        isShowingSettings = false
    }

    private func handleSettingsDismissed() {
        guard let pendingExit else { return }
        self.pendingExit = nil

        switch pendingExit {
        case .cancel:
            onCancel?()
        case .save(let task):
            onSave(task)
        }
    }

}

struct DummyConfigurator: View {
    var body: some View {
        Text(L10n.taskDummyDescription)
            .font(.body)
            .foregroundStyle(OAColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PreviewIdentity: Hashable {
    let configuration: PreviewTaskConfiguration
    let generation: Int
}

private enum PendingConfiguratorExit: Hashable {
    case cancel
    case save(AlarmTask)
}

private enum PreviewTaskConfiguration: Hashable {
    case dummy
    case math(difficulty: MathDifficulty)
    case shake(intensity: Int)
    case memory(difficulty: Int)
    case steps(count: Int)
    case scanObject(objectClass: String)

    init(task: AlarmTask) {
        switch task {
        case .dummy:
            self = .dummy
        case let .math(difficulty, _):
            self = .math(difficulty: difficulty)
        case let .shake(intensity):
            self = .shake(intensity: intensity)
        case let .memory(difficulty, _):
            self = .memory(difficulty: difficulty)
        case let .steps(count):
            self = .steps(count: count)
        case let .scanObject(objectClass):
            self = .scanObject(objectClass: objectClass)
        }
    }
}
