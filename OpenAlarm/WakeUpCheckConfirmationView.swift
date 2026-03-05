import SwiftUI

struct WakeUpCheckConfirmationView: View {
    let alarmID: UUID
    @EnvironmentObject private var alarmStore: AlarmStore

    @State private var remainingSeconds: Int = 0
    @State private var deadline: Date = .distantFuture
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "alarm.waves.left.and.right.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(OAColor.actionCyan)

                Text(L10n.wakeCheckConfirmTitle)
                    .font(.title.bold())
                    .foregroundStyle(OAColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(L10n.wakeCheckConfirmSubtitle)
                    .font(.body)
                    .foregroundStyle(OAColor.textSecondary)
                    .multilineTextAlignment(.center)

                Text(formattedCountdown)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(remainingSeconds <= 10 ? OAColor.danger : OAColor.textPrimary)
                    .contentTransition(.numericText())
                    .animation(.default, value: remainingSeconds)
            }
            .padding(24)
            .oaGlassCard()

            Button {
                Task {
                    await alarmStore.confirmWakeUpCheck(for: alarmID)
                }
            } label: {
                Text(L10n.wakeCheckConfirmAction)
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.glassProminent)
            .tint(OAColor.actionCyan)
            .accessibilityIdentifier("wake_check_confirm_awake")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OAColor.background.ignoresSafeArea())
        .interactiveDismissDisabled()
        .onAppear {
            Task { @MainActor in
                if let resolvedDeadline = await alarmStore.applyWakeUpCheckGracePeriodIfNeeded(for: alarmID) {
                    deadline = resolvedDeadline
                } else {
                    alarmStore.wakeUpCheckConfirmationPresentation = nil
                    return
                }
                updateRemaining()
                startTimer()
            }
        }
        .onDisappear {
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
            alarmStore.wakeUpCheckConfirmationPresentation = nil
        }
    }
}
