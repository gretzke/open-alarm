import SwiftUI

struct NapBannerView: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: Circle())
                        .overlay(
                            Circle()
                                .stroke(OAColor.glassStroke.opacity(0.75), lineWidth: 0.8)
                        )

                    Image(systemName: "zzz")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(OAColor.actionCyan)
                }

                Text(L10n.napBannerTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(OAColor.textPrimary)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(OAColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .oaGlassCard()
            .contentShape(RoundedRectangle(cornerRadius: OARadius.card, style: .continuous))
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nap_banner_take_nap")
    }
}

struct ActiveNapRowView: View {
    let nap: UserAlarm
    let now: Date
    let onPause: () -> Void
    let onContinue: () -> Void
    let onAddOneMinute: () -> Void
    let onAddFiveMinutes: () -> Void
    let onAddTenMinutes: () -> Void
    let onDelete: () -> Void

    private var remainingTimeString: String {
        let remaining = Int(nap.remainingSeconds(referenceDate: now))
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(nap.snoozeCount > 0 ? L10n.napActiveSnoozingTitle : L10n.napActiveTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(OAColor.textPrimary)
                    .padding(.trailing, !nap.isPaused ? 156 : 0)

                Spacer(minLength: 0)
            }
            .overlay(alignment: .topTrailing) {
                if !nap.isPaused {
                    HStack(spacing: 8) {
                        extraTimeButton("+1", accessibilityLabel: L10n.napActiveAddOneMinute, action: onAddOneMinute)
                        extraTimeButton("+5", accessibilityLabel: L10n.napActiveAddFiveMinutes, action: onAddFiveMinutes)
                        extraTimeButton("+10", accessibilityLabel: L10n.napActiveAddTenMinutes, action: onAddTenMinutes)
                    }
                }
            }

            Text(remainingTimeString)
                .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(OAColor.textPrimary)

            HStack(spacing: 10) {
                Button {
                    if nap.isPaused {
                        onContinue()
                    } else {
                        onPause()
                    }
                } label: {
                    Label(nap.isPaused ? L10n.actionContinue : L10n.actionPause, systemImage: nap.isPaused ? "play.fill" : "pause.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(OAColor.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GlassButtonStyle())

                Button(action: onDelete) {
                    Label(L10n.actionDelete, systemImage: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(OAColor.danger)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(18)
        .oaGlassCard()
        .padding(.vertical, 6)
    }

    private func extraTimeButton(
        _ title: String,
        accessibilityLabel: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.bold))
                .foregroundStyle(OAColor.actionCyan)
                .padding(.horizontal, 10)
                .frame(minWidth: 44, minHeight: 34)
                .contentShape(RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .oaGlassPanel(cornerRadius: OARadius.chip)
        .accessibilityLabel(accessibilityLabel)
    }
}
