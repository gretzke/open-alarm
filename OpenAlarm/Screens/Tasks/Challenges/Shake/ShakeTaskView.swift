import SwiftUI

@MainActor
struct ShakeTaskView: View {
    let intensity: Int
    let mode: TaskMode
    var onEvent: (TaskEvent) -> Void

    @State private var model: ShakeEnergyModel
    @State private var token: MotionService.Token?
    @State private var ramp: HapticRamp
    @State private var displayedProgress = 0.0
    @State private var receivedSample = false
    @State private var showingFallback = false
    @State private var didComplete = false
    @State private var lastPublishTime: TimeInterval?
    @State private var noSampleTask: Task<Void, Never>?

    @ScaledMetric(relativeTo: .largeTitle) private var percentageFontSize: CGFloat = 96

    init(intensity: Int, mode: TaskMode, onEvent: @escaping (TaskEvent) -> Void) {
        let clampedIntensity = min(max(intensity, 1), 5)
        self.intensity = clampedIntensity
        self.mode = mode
        self.onEvent = onEvent
        _model = State(initialValue: ShakeEnergyModel(intensity: clampedIntensity))
        _ramp = State(initialValue: HapticRamp())
    }

    var body: some View {
        VStack(spacing: OASpacing.l) {
            Spacer()

            if showingFallback {
                fallbackControl
            } else {
                shakeContent
            }

            Spacer()
        }
        .padding(OASpacing.screenMargin)
        .onAppear(perform: beginMotion)
        .onDisappear(perform: stopEverything)
    }

    private var shakeContent: some View {
        VStack(spacing: OASpacing.l) {
            Text(L10n.taskShakeInstruction)
                .font(OADawnType.chip)
                .foregroundStyle(.white)

            Text(displayedProgress, format: .percent.precision(.fractionLength(0)))
                .font(OADawnType.display(percentageFontSize))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    private var fallbackControl: some View {
        Button {
            completeTask()
        } label: {
            Text(L10n.taskShakeUnavailableFallback)
                .font(OADawnType.button)
                .foregroundStyle(DawnPalette.inkDark)
                .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
        }
        .background(Color.white, in: Capsule())
        .buttonStyle(.plain)
    }

    private func beginMotion() {
        guard !didComplete, token == nil else {
            return
        }

        token = MotionService.shared.subscribe { magnitude, dt in
            receiveSample(magnitude: magnitude, dt: dt)
        }

        guard token != nil else {
            if mode == .wake {
                showingFallback = true
                ramp.stop()
            }
            return
        }

        guard mode == .wake else {
            return
        }

        noSampleTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            guard !Task.isCancelled, !receivedSample, !didComplete else {
                return
            }

            showingFallback = true
            stopEverything()
        }
    }

    private func receiveSample(magnitude: Double, dt: Double) {
        guard !didComplete, !showingFallback else {
            return
        }

        receivedSample = true
        noSampleTask?.cancel()
        noSampleTask = nil

        model.ingest(magnitude: magnitude, dt: dt)
        publishProgressIfNeeded()

        if model.isComplete {
            completeTask()
        }
    }

    private func publishProgressIfNeeded() {
        let now = Date.timeIntervalSinceReferenceDate
        guard lastPublishTime.map({ now - $0 >= 0.1 }) ?? true else {
            return
        }

        lastPublishTime = now
        displayedProgress = model.progress
        onEvent(.progress(displayedProgress))
        ramp.update(progress: displayedProgress)
    }

    private func completeTask() {
        guard !didComplete else {
            return
        }

        didComplete = true
        stopEverything()
        onEvent(.completed)
    }

    private func stopEverything() {
        if let token {
            MotionService.shared.cancel(token)
            self.token = nil
        }
        noSampleTask?.cancel()
        noSampleTask = nil
        ramp.stop()
    }
}
