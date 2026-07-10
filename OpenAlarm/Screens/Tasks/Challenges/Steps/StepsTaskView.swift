import SwiftUI

@MainActor
struct StepsTaskView: View {
    let count: Int
    let mode: TaskMode
    var onEvent: (TaskEvent) -> Void

    @State private var displayedSteps = 0
    @State private var showingFallback = false
    @State private var didComplete = false
#if DEBUG
    @State private var simulationTask: Task<Void, Never>?
#endif

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
        .onAppear(perform: beginPedometer)
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

#if DEBUG
            if mode == .preview {
                debugSimulationControl
            }
#endif
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

#if DEBUG
    private var debugSimulationControl: some View {
        Button(action: {}) {
            Text(L10n.taskStepsSimulate)
                .font(OADawnType.button)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
                .padding(.horizontal, OASpacing.l)
                .background(Color.white.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in startSimulation() }
                .onEnded { _ in stopSimulation() }
        )
    }
#endif

    private func beginPedometer() {
        guard !didComplete else {
            return
        }

        guard PedometerService.shared.isAvailable, !PedometerService.shared.isDenied else {
            handleUnavailablePedometer()
            return
        }

        PedometerService.shared.startUpdates(receiveSteps, onError: handleUnavailablePedometer)
    }

    private func receiveSteps(_ steps: Int) {
        guard !didComplete, !showingFallback else {
            return
        }

        displayedSteps = max(steps, 0)
        onEvent(.progress(min(Double(displayedSteps) / Double(count), 1)))

        if displayedSteps >= count {
            completeTask()
        }
    }

    private func handleUnavailablePedometer() {
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
        PedometerService.shared.stopUpdates()
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
                receiveSteps(displayedSteps + 1)
                do {
                    try await Task.sleep(for: .milliseconds(50))
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
