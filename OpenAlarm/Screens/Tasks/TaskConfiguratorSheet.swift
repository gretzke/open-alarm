import AVFoundation
import SwiftUI

struct TaskConfiguratorContent: View {
    let onSave: (AlarmTask) -> Void
    let onCancel: (() -> Void)?

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var alarmStore: AlarmStore
    @State private var draft: AlarmTask
    @State private var previewProgress = 0.3
    @State private var previewGeneration = 0
    @State private var previewResetTask: Task<Void, Never>?
    @State private var cameraPermissionFlowStep: CameraPermissionFlowStep?
    @State private var saveAfterPermissionCoverDismisses = false

    init(
        initial: AlarmTask,
        onSave: @escaping (AlarmTask) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: initial)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                preview
                    .frame(height: geometry.size.height * 0.5)
                    .padding(.horizontal, OASpacing.screenMargin)
                    .padding(.top, OASpacing.s)
                    .padding(.bottom, OASpacing.m)

                ScrollView {
                    TaskRegistry.descriptor(for: draft)
                        .makeConfigurator($draft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(OASpacing.screenMargin)
                }
                .background(OAColor.background)
            }
        }
        .navigationTitle(L10n.taskConfiguratorTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.taskConfiguratorSave) {
                    attemptSave()
                }
            }
            if let onCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel, action: onCancel)
                }
            }
        }
        .onChange(of: draft) { _, _ in
            previewResetTask?.cancel()
            previewResetTask = nil
            previewProgress = 0.3
        }
        .onDisappear {
            previewResetTask?.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active,
                  cameraPermissionFlowStep == .denied,
                  AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                return
            }
            cameraPermissionFlowStep = nil
        }
        .fullScreenCover(
            item: $cameraPermissionFlowStep,
            onDismiss: handlePermissionCoverDismissed
        ) { step in
            switch step {
            case .prePrompt:
                CameraPermissionPrePromptView(
                    onRequestPermission: requestCameraPermission,
                    onCancel: { cameraPermissionFlowStep = nil }
                )
            case .denied:
                CameraPermissionDeniedView(
                    onOpenSettings: alarmStore.openSettings,
                    onCancel: { cameraPermissionFlowStep = nil }
                )
            }
        }
    }

    private var preview: some View {
        ZStack {
            DawnBackground(progress: previewProgress)

            TaskRegistry.descriptor(for: draft)
                .makeTaskView(draft, mode: .preview, onEvent: handlePreviewEvent)
                .id(PreviewIdentity(task: draft, generation: previewGeneration))
        }
        .clipShape(RoundedRectangle(cornerRadius: OARadius.card, style: .continuous))
    }

    private func handlePreviewEvent(_ event: TaskEvent) {
        switch event {
        case .progress(let progress):
            previewProgress = 0.3 + min(max(progress, 0), 1) * 0.4
        case .completed:
            Haptics.success()
            withAnimation(.easeInOut(duration: 0.2)) {
                previewProgress = min(previewProgress + 0.15, 1)
            }
            schedulePreviewReset()
        }
    }

    private func schedulePreviewReset() {
        previewResetTask?.cancel()
        let completedDraft = draft
        previewResetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(800))
            } catch {
                return
            }

            guard !Task.isCancelled, draft == completedDraft else {
                return
            }

            previewProgress = 0.3
            previewGeneration &+= 1
            previewResetTask = nil
        }
    }

    private func attemptSave() {
        guard TaskRegistry.descriptor(for: draft).requiredPermission == .camera else {
            onSave(draft)
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            onSave(draft)
        case .notDetermined:
            cameraPermissionFlowStep = .prePrompt
        case .denied, .restricted:
            cameraPermissionFlowStep = .denied
        @unknown default:
            cameraPermissionFlowStep = .denied
        }
    }

    private func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                if granted {
                    saveAfterPermissionCoverDismisses = true
                    cameraPermissionFlowStep = nil
                } else {
                    cameraPermissionFlowStep = .denied
                }
            }
        }
    }

    private func handlePermissionCoverDismissed() {
        guard saveAfterPermissionCoverDismisses else {
            return
        }
        saveAfterPermissionCoverDismisses = false
        onSave(draft)
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
    let task: AlarmTask
    let generation: Int
}
