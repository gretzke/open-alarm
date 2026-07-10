@preconcurrency import AVFoundation
import Foundation
import Vision

/// Owns the camera and Vision work for a scan-object task instance.
/// Session configuration and start/stop work stay off the main thread so the
/// dawn UI remains responsive while the preview is visible.
@MainActor
final class ObjectScanner: NSObject, ObservableObject {
    @Published private(set) var lastConfidence = 0.0
    @Published private(set) var isAvailable = true

    let previewLayer: AVCaptureVideoPreviewLayer?

    private let camera: CameraSession
    private let supportedEntries: [ScanObjectCatalog.Entry]
    private var generation = UUID()

    override init() {
        // Runtime validation is deliberately unconditional. A taxonomy change
        // must fail open rather than leave a release build with an impossible task.
        let request = VNClassifyImageRequest()
        request.revision = VNClassifyImageRequestRevision2
        let supportedIdentifiers = Set((try? request.supportedIdentifiers()) ?? [])
        supportedEntries = ScanObjectCatalog.entries.filter { supportedIdentifiers.contains($0.id) }

        let camera = CameraSession()
        self.camera = camera
        previewLayer = camera.previewLayer
        super.init()

        previewLayer?.videoGravity = .resizeAspectFill
        camera.onConfidence = { [weak self] confidence, generation in
            DispatchQueue.main.async { [weak self] in
                self?.receive(confidence: confidence, generation: generation)
            }
        }
        camera.onFailure = { [weak self] generation in
            DispatchQueue.main.async { [weak self] in
                self?.receiveFailure(generation: generation)
            }
        }
    }

    var hasSupportedCatalog: Bool {
        !supportedEntries.isEmpty
    }

    /// Resolves stale or unsupported persisted IDs to the first entry that the
    /// runtime classifier supports. Nil means this task must fail open.
    func resolvedTarget(for target: String) -> String? {
        if supportedEntries.contains(where: { $0.id == target }) {
            return target
        }
        return supportedEntries.first?.id
    }

    func start(target: String) {
        guard let target = resolvedTarget(for: target) else {
            isAvailable = false
            return
        }

        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            isAvailable = false
            return
        }

        isAvailable = true
        lastConfidence = 0
        generation = UUID()
        let currentGeneration = generation

        camera.start(target: target, generation: currentGeneration)
    }

    func stop() {
        generation = UUID()
        camera.stop()
    }

    private func receive(confidence: Double, generation: UUID) {
        guard self.generation == generation else {
            return
        }
        lastConfidence = min(max(confidence, 0), 1)
    }

    private func receiveFailure(generation: UUID) {
        guard self.generation == generation else {
            return
        }
        isAvailable = false
        stop()
    }
}

/// AVFoundation objects are confined to `sessionQueue` and `videoOutputQueue`.
/// The unchecked Sendable conformance documents that confinement for dispatch
/// closures while `ObjectScanner` remains main-actor isolated for SwiftUI.
private final class CameraSession: @unchecked Sendable {
    var onConfidence: ((Double, UUID) -> Void)?
    var onFailure: ((UUID) -> Void)?

    let session = AVCaptureSession()
    let previewLayer: AVCaptureVideoPreviewLayer

    private let sessionQueue = DispatchQueue(label: "com.gretzke.openalarm.object-scanner.session")
    private let videoOutputQueue = DispatchQueue(label: "com.gretzke.openalarm.object-scanner.vision")
    private let output = AVCaptureVideoDataOutput()
    private let processor = ClassificationProcessor()

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        processor.onConfidence = { [weak self] confidence, generation in
            self?.onConfidence?(confidence, generation)
        }
        processor.onFailure = { [weak self] generation in
            self?.onFailure?(generation)
        }
    }

    func start(target: String, generation: UUID) {
        sessionQueue.async { [weak self] in
            self?.configureAndStart(target: target, generation: generation)
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.output.setSampleBufferDelegate(nil, queue: nil)
            self.processor.cancel()
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.session.beginConfiguration()
            self.session.inputs.forEach(self.session.removeInput)
            self.session.outputs.forEach(self.session.removeOutput)
            self.session.commitConfiguration()
        }
    }

    private func configureAndStart(target: String, generation: UUID) {
        session.beginConfiguration()

        output.setSampleBufferDelegate(nil, queue: nil)
        processor.cancel()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)

        do {
            guard let device = AVCaptureDevice.default(for: .video) else {
                throw ScannerError.unavailable
            }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw ScannerError.unavailable }
            session.addInput(input)

            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
            guard session.canAddOutput(output) else {
                throw ScannerError.unavailable
            }
            session.addOutput(output)
            processor.configure(target: target, generation: generation)
            output.setSampleBufferDelegate(processor, queue: videoOutputQueue)
            session.commitConfiguration()
        } catch {
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            session.commitConfiguration()
            onFailure?(generation)
            return
        }

        session.startRunning()
    }

    private enum ScannerError: Error {
        case unavailable
    }
}

private final class ClassificationProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onConfidence: ((Double, UUID) -> Void)?
    var onFailure: ((UUID) -> Void)?

    private var request: VNClassifyImageRequest?
    private var target = ""
    private var generation: UUID?
    private var lastClassificationTime = CMTime.invalid

    func configure(target: String, generation: UUID) {
        let request = VNClassifyImageRequest()
        request.revision = VNClassifyImageRequestRevision2
        self.request = request
        self.target = target
        self.generation = generation
        lastClassificationTime = .invalid
    }

    func cancel() {
        request?.cancel()
        request = nil
        generation = nil
        target = ""
        lastClassificationTime = .invalid
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let request, let generation else {
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard !lastClassificationTime.isValid || CMTimeGetSeconds(timestamp - lastClassificationTime) >= 1.0 / 3.0 else {
            return
        }
        lastClassificationTime = timestamp

        do {
            let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
            try handler.perform([request])
            let confidence = request.results?
                .first(where: { $0.identifier == target })?
                .confidence ?? 0
            onConfidence?(Double(confidence), generation)
        } catch {
            onFailure?(generation)
        }
    }
}
