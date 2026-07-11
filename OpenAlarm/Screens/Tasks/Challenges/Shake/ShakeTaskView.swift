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
    @State private var showingFallback = false
    @State private var didComplete = false
    @State private var lastPublishTime: TimeInterval?
    @State private var lastSampleTime: TimeInterval?
    @State private var resubscribeAttempts = 0
    @State private var watchdogTask: Task<Void, Never>?

    @ScaledMetric(relativeTo: .largeTitle) private var percentageFontSize: CGFloat = 96
    @ScaledMetric(relativeTo: .title2) private var instructionFontSize: CGFloat = 28

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
            Text(displayedProgress, format: .percent.precision(.fractionLength(0)))
                .font(OADawnType.display(percentageFontSize))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Text(L10n.taskShakeInstruction)
                .font(OADawnType.display(instructionFontSize))
                .foregroundStyle(.white)
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
                showFallback(reason: "subscribe returned nil")
            }
            return
        }

        guard mode == .wake else {
            return
        }

        startWatchdog()
    }

    /// Liveness watchdog (wake mode only): covers both startup silence and a
    /// stream that dies after delivering samples. One resubscribe attempt
    /// before failing open keeps the escape path under ~5 seconds.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled, !didComplete, !showingFallback else {
                    return
                }

                let now = Date.timeIntervalSinceReferenceDate
                let isStalled = lastSampleTime.map { now - $0 >= 2.5 } ?? true
                guard isStalled else {
                    continue
                }

                if resubscribeAttempts < 1 {
                    resubscribeAttempts += 1
                    IntentDiagnostics.log("ShakeTask motion stalled; resubscribing (attempt \(resubscribeAttempts))")
                    if let token {
                        MotionService.shared.cancel(token)
                        self.token = nil
                    }
                    token = MotionService.shared.subscribe { magnitude, dt in
                        receiveSample(magnitude: magnitude, dt: dt)
                    }
                    if token == nil {
                        showFallback(reason: "resubscribe returned nil")
                        return
                    }
                } else {
                    showFallback(reason: "motion stalled after resubscribe")
                    return
                }
            }
        }
    }

    private func showFallback(reason: String) {
        IntentDiagnostics.log("ShakeTask fallback shown reason=\(reason)")
        showingFallback = true
        stopEverything()
    }

    private func receiveSample(magnitude: Double, dt: Double) {
        guard !didComplete, !showingFallback else {
            return
        }

        lastSampleTime = Date.timeIntervalSinceReferenceDate

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
        // Haptics only during the real challenge: in the configurator preview the
        // ramp reacts to incidental desk movement and reads as broken feedback.
        if mode == .wake {
            ramp.update(progress: displayedProgress)
        }
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
        watchdogTask?.cancel()
        watchdogTask = nil
        ramp.stop()
    }
}
