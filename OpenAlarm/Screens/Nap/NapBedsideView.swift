import SwiftUI

struct NapBedsideView: View {
    let nap: UserAlarm
    let onClose: () -> Void
    @EnvironmentObject private var alarmStore: AlarmStore
    @State private var glowEnabled = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = nap.remainingSeconds(referenceDate: context.date)
            let progress =
                glowEnabled
                ? NapDawnProgress.value(
                    remainingSeconds: remaining,
                    durationSeconds: Double(nap.durationMinutes ?? 0) * 60,
                    isPaused: nap.isPaused,
                    isSnoozing: nap.snoozeCount > 0
                ) : 0

            NavigationStack {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if glowEnabled {
                        DawnBackground(progress: progress)
                            .opacity(progress)
                    }

                    FoldAwareContent {
                        AdaptiveScreenScrollView {
                            VStack(spacing: OASpacing.xl) {
                                Text(
                                    nap.isPaused
                                        ? L10n.napActivePaused : (nap.snoozeCount > 0 ? L10n.napActiveSnoozingTitle : L10n.napActiveTitle)
                                )
                                .font(.title2.weight(.semibold))

                                Text(
                                    Duration.seconds(remaining.rounded(.up)),
                                    format: .time(pattern: remaining >= 3600 ? .hourMinuteSecond : .minuteSecond)
                                )
                                .font(.largeTitle.scaled(by: 2.6).weight(.black).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.3)
                                .accessibilityIdentifier("nap_bedside_countdown")

                                Button(
                                    nap.isPaused ? L10n.actionContinue : L10n.actionPause,
                                    systemImage: nap.isPaused ? "play.fill" : "pause.fill"
                                ) {
                                    Task {
                                        if nap.isPaused {
                                            await alarmStore.resumeNap()
                                        } else {
                                            await alarmStore.pauseNap()
                                        }
                                    }
                                }
                                .buttonStyle(.glass)
                                .controlSize(.large)
                                .disabled(!nap.isPaused && remaining <= 0)
                                .accessibilityIdentifier("nap_bedside_pause_resume")
                            }
                            .foregroundStyle(DawnPalette.ink(progress: progress))
                            .padding(OASpacing.xl)
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.actionClose, systemImage: "xmark", action: onClose)
                                .foregroundStyle(DawnPalette.ink(progress: progress))
                                .accessibilityIdentifier("nap_bedside_close")
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Toggle(isOn: $glowEnabled) {
                                Label(L10n.napBedsideGlow, systemImage: "sun.max.fill")
                            }
                            .toggleStyle(.button)
                            .accessibilityIdentifier("nap_bedside_glow")
                        }
                    }
                    .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                    .toolbarColorScheme(progress > 0.75 ? .light : .dark, for: .navigationBar)
                }
            }
            .tint(DawnPalette.ink(progress: progress))
            .environment(\.colorScheme, progress > 0.75 ? .light : .dark)
        }
        .fontDesign(.rounded)
        .preferredColorScheme(.dark)
    }
}
