import SwiftUI

@MainActor
struct StepsTaskView: View {
    let count: Int
    let mode: TaskMode
    var onEvent: (TaskEvent) -> Void

    @State private var displayedSteps = 0
    @State private var showingFallback = false
    @State private var didComplete = false

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
        }
    }

    private var fallbackControl: some View {
        Group {
            if mode == .preview {
                VStack(spacing: OASpacing.m) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 44, weight: .semibold))

                    Text(L10n.taskStepsUnavailablePreview)
                        .font(OADawnType.chip)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
            } else {
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
        }
    }

    private func beginPedometer() {
        guard !didComplete else {
            return
        }

        displayedSteps = 0
        PedometerService.shared.startUpdates(
            receiveSteps,
            onError: handleUnavailable
        )
    }

    private func receiveSteps(_ steps: Int) {
        guard !didComplete, !showingFallback else {
            return
        }

        displayedSteps = steps
        onEvent(.progress(min(Double(displayedSteps) / Double(count), 1)))

        if displayedSteps >= count {
            completeTask()
        }
    }

    private func handleUnavailable() {
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
        // No success haptic here: the hosts (TaskContainerView / TaskConfiguratorSheet)
        // own completion haptics, same as math/memory/shake.
        onEvent(.completed)
    }

    private func stopEverything() {
        PedometerService.shared.stopUpdates()
    }
}
