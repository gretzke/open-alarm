import SwiftUI

@MainActor
struct StepsTaskView: View {
    let count: Int
    let mode: TaskMode
    var onEvent: (TaskEvent) -> Void

    @State private var detector = StepDetector()
    @State private var token: MotionService.Token?
    @State private var displayedSteps = 0
    @State private var receivedSample = false
    @State private var showingFallback = false
    @State private var didComplete = false
    @State private var noSampleTask: Task<Void, Never>?

    @ScaledMetric(relativeTo: .largeTitle) private var counterFontSize: CGFloat = 76

    init(count: Int, mode: TaskMode, onEvent: @escaping (TaskEvent) -> Void) {
        self.count = min(max(count, 10), 100)
        self.mode = mode
        self.onEvent = onEvent
    }

    var body: some View {
        VStack(spacing: OASpacing.l) {
            Spacer()

            if showingFallback {
                fallbackControl
            } else {
                stepsContent
            }

            Spacer()
        }
        .padding(OASpacing.screenMargin)
        .onAppear(perform: beginMotion)
        .onDisappear(perform: stopEverything)
    }

    private var stepsContent: some View {
        VStack(spacing: OASpacing.l) {
            Text(L10n.taskStepsTitle)
                .font(OADawnType.chip)
                .foregroundStyle(.white)

            Text(L10n.taskStepsCounter(displayedSteps, goal: count))
                .font(OADawnType.display(counterFontSize))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.45)
        }
    }

    private var fallbackControl: some View {
        Button {
            completeTask()
        } label: {
            Text(L10n.taskStepsUnavailableFallback)
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

        detector.reset()
        displayedSteps = 0
        receivedSample = false
        token = MotionService.shared.subscribe { magnitude, dt in
            receiveSample(magnitude: magnitude, dt: dt)
        }

        guard token != nil else {
            handleUnavailableMotion()
            return
        }

        noSampleTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }

            guard !Task.isCancelled, !receivedSample, !didComplete else {
                return
            }

            handleUnavailableMotion()
        }
    }

    private func receiveSample(magnitude: Double, dt: Double) {
        guard !didComplete, !showingFallback else {
            return
        }

        receivedSample = true
        noSampleTask?.cancel()
        noSampleTask = nil

        let creditedSteps = detector.process(magnitude: magnitude, dt: dt)
        guard creditedSteps > 0 else {
            return
        }

        displayedSteps = detector.stepCount
        onEvent(.progress(min(Double(displayedSteps) / Double(count), 1)))

        if displayedSteps >= count {
            completeTask()
        }
    }

    private func handleUnavailableMotion() {
        // Previews intentionally retain their DEBUG simulator when Core Motion is
        // unavailable, matching the shake task's simulator-friendly behavior.
        guard mode == .wake else {
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
        // No success haptic here: the hosts (TaskContainerView / TaskConfiguratorSheet)
        // own completion haptics, same as math/memory/shake.
        onEvent(.completed)
    }

    private func stopEverything() {
        if let token {
            MotionService.shared.cancel(token)
            self.token = nil
        }
        noSampleTask?.cancel()
        noSampleTask = nil
    }
}
