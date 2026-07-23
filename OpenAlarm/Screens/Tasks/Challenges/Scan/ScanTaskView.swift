import AVFoundation
import SwiftUI
import UIKit

@MainActor
struct ScanTaskView: View {
    let objectClass: String
    let mode: TaskMode
    var onEvent: (TaskEvent) -> Void

    @StateObject private var scanner: ObjectScanner
    @State private var target: String?
    @State private var consecutiveHits = 0
    @State private var showingFallback = false
    @State private var didComplete = false

    init(objectClass: String, mode: TaskMode, onEvent: @escaping (TaskEvent) -> Void) {
        let scanner = ObjectScanner()
        self.objectClass = objectClass
        self.mode = mode
        self.onEvent = onEvent
        _scanner = StateObject(wrappedValue: scanner)
        _target = State(initialValue: scanner.resolvedTarget(for: objectClass))
    }

    var body: some View {
        Group {
            if showingFallback || target == nil {
                fallbackContent
            } else {
                scannerContent
            }
        }
        .padding(OASpacing.screenMargin)
        .onAppear(perform: beginScanning)
        .onDisappear(perform: stopEverything)
        .onChange(of: scanner.lastSample) { _, sample in
            handleSample(sample)
        }
        .onChange(of: scanner.isAvailable) { _, isAvailable in
            if !isAvailable {
                showFallback()
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
                    lockOnMeter
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

    // Lock-on progress: fills one segment per consecutive match frame. No raw
    // classifier numbers — absolute Vision confidences are meaningless to users.
    private var lockOnMeter: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(.white.opacity(0.28))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.white)
                        .frame(
                            width: geometry.size.width
                                * Double(consecutiveHits)
                                / Double(ScanMatchPolicy.requiredConsecutiveMatches)
                        )
                }
        }
        .frame(height: OASpacing.s)
        .animation(.easeOut(duration: 0.25), value: consecutiveHits)
        .padding(OASpacing.m)
        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous))
    }

    @ViewBuilder
    private var fallbackContent: some View {
        if mode == .preview {
            VStack(spacing: OASpacing.m) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 44, weight: .semibold))

                Text(L10n.taskScanUnavailablePreview)
                    .font(OADawnType.chip)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Button {
                completeTask()
            } label: {
                Text(L10n.taskScanUnavailableFallback)
                    .font(OADawnType.button)
                    .foregroundStyle(DawnPalette.inkDark)
                    .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
                    .contentShape(Rectangle())
            }
            .background(.white, in: Capsule())
            .buttonStyle(.plain)
        }
    }

    private func beginScanning() {
        guard !didComplete, let target else {
            showFallback()
            return
        }

        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            showFallback()
            return
        }

        scanner.start(target: target)
    }

    private func handleSample(_ sample: ScanSample?) {
        guard !didComplete, !showingFallback, let sample else {
            return
        }

        guard sample.isMatch else {
            consecutiveHits = 0
            onEvent(.progress(0))
            return
        }

        consecutiveHits += 1
        onEvent(.progress(Double(consecutiveHits) / Double(ScanMatchPolicy.requiredConsecutiveMatches)))
        Haptics.impact(.light)

        if consecutiveHits >= ScanMatchPolicy.requiredConsecutiveMatches {
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
    }
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
