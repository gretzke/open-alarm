import AVFoundation
import SwiftUI
import UIKit

@MainActor
struct ScanTaskView: View {
    let objectClass: String
    let mode: TaskMode
    var onEvent: (TaskEvent) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var alarmStore: AlarmStore
    @StateObject private var scanner: ObjectScanner
    @State private var target: String?
    @State private var cameraAuthorizationStatus: AVAuthorizationStatus
    @State private var cameraPermissionFlowStep: CameraPermissionFlowStep?
    @State private var startScannerAfterPermissionCoverDismisses = false
    @State private var consecutiveHits = 0
    @State private var showingFallback = false
    @State private var didComplete = false
#if DEBUG
    @State private var simulationTask: Task<Void, Never>?
#endif

    init(objectClass: String, mode: TaskMode, onEvent: @escaping (TaskEvent) -> Void) {
        let scanner = ObjectScanner()
        self.objectClass = objectClass
        self.mode = mode
        self.onEvent = onEvent
        _scanner = StateObject(wrappedValue: scanner)
        _target = State(initialValue: scanner.resolvedTarget(for: objectClass))
        _cameraAuthorizationStatus = State(
            initialValue: AVCaptureDevice.authorizationStatus(for: .video)
        )
    }

    var body: some View {
        Group {
            if showingFallback || target == nil {
                fallbackContent
            } else if mode == .preview, cameraAuthorizationStatus != .authorized {
                cameraPermissionPlaceholder
            } else {
                scannerContent
            }
        }
        .padding(OASpacing.screenMargin)
        .onAppear(perform: beginScanning)
        .onDisappear(perform: stopEverything)
        .onChange(of: scanner.lastConfidence) { _, confidence in
            handleConfidence(confidence)
        }
        .onChange(of: scanner.isAvailable) { _, isAvailable in
            if !isAvailable {
                showFallback()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                return
            }
            refreshCameraAuthorization()
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

    private var scannerContent: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreviewLayerView(previewLayer: scanner.previewLayer)

                VStack {
                    targetChip
                    Spacer()
                    confidenceMeter
                }
                .padding(OASpacing.m)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: OARadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: OARadius.card, style: .continuous)
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private var targetChip: some View {
        Text(L10n.taskScanObjectName(target ?? objectClass))
            .font(OADawnType.chip)
            .foregroundStyle(DawnPalette.inkDark)
            .padding(.horizontal, OASpacing.m)
            .padding(.vertical, OASpacing.s)
            .background(.white.opacity(0.88), in: Capsule())
    }

    private var confidenceMeter: some View {
        VStack(alignment: .leading, spacing: OASpacing.xs) {
            GeometryReader { geometry in
                Capsule()
                    .fill(.white.opacity(0.28))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.white)
                            .frame(width: geometry.size.width * min(max(scanner.lastConfidence / 0.25, 0), 1))
                    }
            }
            .frame(height: OASpacing.s)

            Text(scanner.lastConfidence, format: .percent.precision(.fractionLength(0)))
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .padding(OASpacing.m)
        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous))
    }

    private var fallbackContent: some View {
        VStack(spacing: OASpacing.m) {
            Button {
                completeTask()
            } label: {
                Text(L10n.taskScanUnavailableFallback)
                    .font(OADawnType.button)
                    .foregroundStyle(DawnPalette.inkDark)
                    .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
            }
            .background(.white, in: Capsule())
            .buttonStyle(.plain)

#if DEBUG
            if mode == .preview {
                debugSimulationControl
            }
#endif
        }
    }

    private var cameraPermissionPlaceholder: some View {
        VStack(spacing: OASpacing.m) {
            Image(systemName: "camera.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)

            Text(L10n.taskScanCameraPlaceholder)
                .font(OADawnType.chip)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Button(action: attemptEnableCamera) {
                Text(L10n.taskScanEnableCamera)
                    .font(OADawnType.button)
                    .foregroundStyle(DawnPalette.inkDark)
                    .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
            }
            .background(.white, in: Capsule())
            .buttonStyle(.plain)
        }
    }

#if DEBUG
    private var debugSimulationControl: some View {
        Button(action: {}) {
            Text(L10n.taskScanSimulate)
                .font(OADawnType.button)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
                .padding(.horizontal, OASpacing.l)
                .background(.white.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in startSimulation() }
                .onEnded { _ in stopSimulation() }
        )
    }
#endif

    private func beginScanning() {
        guard !didComplete, let target else {
            showFallback()
            return
        }

        cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch cameraAuthorizationStatus {
        case .authorized:
            scanner.start(target: target)
        case .notDetermined, .denied, .restricted:
            if mode == .wake {
                showFallback()
            }
        @unknown default:
            if mode == .wake {
                showFallback()
            }
        }
    }

    private func attemptEnableCamera() {
        cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch cameraAuthorizationStatus {
        case .authorized:
            beginScanning()
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
                cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
                if granted {
                    startScannerAfterPermissionCoverDismisses = true
                    cameraPermissionFlowStep = nil
                } else {
                    cameraPermissionFlowStep = .denied
                }
            }
        }
    }

    private func refreshCameraAuthorization() {
        let previousStatus = cameraAuthorizationStatus
        cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

        guard cameraAuthorizationStatus == .authorized else {
            return
        }

        if cameraPermissionFlowStep == .denied {
            startScannerAfterPermissionCoverDismisses = true
            cameraPermissionFlowStep = nil
        } else if mode == .preview, previousStatus != .authorized {
            beginScanning()
        }
    }

    private func handlePermissionCoverDismissed() {
        guard startScannerAfterPermissionCoverDismisses else {
            return
        }
        startScannerAfterPermissionCoverDismisses = false
        beginScanning()
    }

    private func handleConfidence(_ confidence: Double) {
        guard !didComplete, !showingFallback else {
            return
        }

        guard confidence >= 0.25 else {
            consecutiveHits = 0
            onEvent(.progress(0))
            return
        }

        consecutiveHits += 1
        onEvent(.progress(Double(consecutiveHits) / 4))
        Haptics.impact(.light)

        if consecutiveHits >= 4 {
            completeTask()
        }
    }

    private func showFallback() {
        guard !didComplete else {
            return
        }
        showingFallback = true
        stopEverything()
    }

    private func completeTask() {
        guard !didComplete else {
            return
        }
        didComplete = true
        stopEverything()
        // Completion haptics belong to TaskContainerView / TaskConfiguratorSheet.
        onEvent(.completed)
    }

    private func stopEverything() {
        scanner.stop()
#if DEBUG
        stopSimulation()
#endif
    }

#if DEBUG
    private func startSimulation() {
        guard simulationTask == nil, !didComplete else {
            return
        }

        simulationTask = Task { @MainActor in
            while !Task.isCancelled, !didComplete {
                handleConfidence(1)
                do {
                    try await Task.sleep(for: .milliseconds(333))
                } catch {
                    return
                }
            }
        }
    }

    private func stopSimulation() {
        simulationTask?.cancel()
        simulationTask = nil
    }
#endif
}

private struct CameraPreviewLayerView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer?

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        attachPreviewLayer(to: view)
        return view
    }

    func updateUIView(_ view: PreviewContainerView, context: Context) {
        attachPreviewLayer(to: view)
    }

    static func dismantleUIView(_ view: PreviewContainerView, coordinator: ()) {
        view.previewLayer?.removeFromSuperlayer()
    }

    private func attachPreviewLayer(to view: PreviewContainerView) {
        guard let previewLayer else {
            return
        }
        if previewLayer.superlayer !== view.layer {
            previewLayer.removeFromSuperlayer()
            view.layer.addSublayer(previewLayer)
        }
        previewLayer.frame = view.bounds
    }
}

private final class PreviewContainerView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer? {
        layer.sublayers?.compactMap { $0 as? AVCaptureVideoPreviewLayer }.first
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}
