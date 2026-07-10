import SwiftUI

struct WakeUpCheckConfirmationView: View {
    let alarmID: UUID
    @EnvironmentObject private var alarmStore: AlarmStore

    @State private var remainingSeconds: Int = 0
    @State private var deadline: Date = .distantFuture
    @State private var timer: Timer?
    @State private var hasDisappeared = false

    @ScaledMetric(relativeTo: .largeTitle) private var countdownFontSize: CGFloat = 64

    var body: some View {
        ZStack {
            DawnBackground(progress: DawnProgress.wakeCheck)

            VStack(spacing: 24) {
                VStack(spacing: 16) {
                    Image(systemName: "alarm.waves.left.and.right.fill")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(DawnPalette.inkDark)

                    Text(L10n.wakeCheckConfirmTitle)
                        .font(OADawnType.display(32))
                        .foregroundStyle(DawnPalette.inkDark)
                        .multilineTextAlignment(.center)

                    Text(L10n.wakeCheckConfirmSubtitle)
                        .font(.body)
                        .foregroundStyle(DawnPalette.inkDark.opacity(0.75))
                        .multilineTextAlignment(.center)

                    Text(formattedCountdown)
                        .font(OADawnType.display(countdownFontSize))
                        .monospacedDigit()
                        .foregroundStyle(remainingSeconds <= 10 ? DawnPalette.stops[1] : DawnPalette.inkDark)
                        .contentTransition(.numericText())
                        .animation(.default, value: remainingSeconds)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .padding(OASpacing.onboardingMargin)
                .background(Color.white.opacity(0.24), in: RoundedRectangle(cornerRadius: OARadius.card, style: .continuous))

                Button {
                    Task {
                        await alarmStore.confirmWakeUpCheck(for: alarmID)
                    }
                } label: {
                    Text(L10n.wakeCheckConfirmAction)
                        .font(OADawnType.button)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
                }
                .background(DawnPalette.inkDark, in: Capsule())
                .buttonStyle(.plain)
                .accessibilityIdentifier("wake_check_confirm_awake")
            }
            .padding(OASpacing.onboardingMargin)
        }
        .interactiveDismissDisabled()
        .onAppear {
            hasDisappeared = false
            Task { @MainActor in
                if let resolvedDeadline = await alarmStore.applyWakeUpCheckGracePeriodIfNeeded(for: alarmID) {
                    guard !hasDisappeared, isCurrentPresentation else { return }
                    deadline = resolvedDeadline
                } else {
                    if isCurrentPresentation {
                        alarmStore.wakeUpCheckConfirmationPresentation = nil
                    }
                    return
                }
                updateRemaining()
                if !hasDisappeared, isCurrentPresentation {
                    startTimer()
                }
            }
        }
        .onDisappear {
            hasDisappeared = true
            timer?.invalidate()
            timer = nil
        }
    }

    private var formattedCountdown: String {
        let clamped = max(0, remainingSeconds)
        let minutes = clamped / 60
        let seconds = clamped % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                updateRemaining()
            }
        }
    }

    private func updateRemaining() {
        let seconds = Int(deadline.timeIntervalSinceNow.rounded(.up))
        remainingSeconds = max(0, seconds)

        if seconds <= 0 {
            timer?.invalidate()
            timer = nil
            if isCurrentPresentation {
                alarmStore.wakeUpCheckConfirmationPresentation = nil
            }
        }
    }

    private var isCurrentPresentation: Bool {
        alarmStore.wakeUpCheckConfirmationPresentation?.id == alarmID
    }
}
