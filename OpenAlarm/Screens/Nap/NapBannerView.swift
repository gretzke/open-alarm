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
                    .font(OAType.cardTitle)
                    .foregroundStyle(OAColor.textPrimary)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(OAColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(OASpacing.cardPadding)
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

    @ScaledMetric(relativeTo: .largeTitle) private var countdownFontSize: CGFloat = 38

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
            HStack(alignment: .center, spacing: OASpacing.s) {
                Text(nap.snoozeCount > 0 ? L10n.napActiveSnoozingTitle : L10n.napActiveTitle)
                    .font(OAType.cardTitle)
                    .foregroundStyle(OAColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: OASpacing.s)

                if !nap.isPaused {
                    HStack(spacing: OASpacing.s) {
                        extraTimeButton("+1", accessibilityLabel: L10n.napActiveAddOneMinute, action: onAddOneMinute)
                        extraTimeButton("+5", accessibilityLabel: L10n.napActiveAddFiveMinutes, action: onAddFiveMinutes)
                        extraTimeButton("+10", accessibilityLabel: L10n.napActiveAddTenMinutes, action: onAddTenMinutes)
                    }
                    .layoutPriority(1)
                }
            }

            Text(remainingTimeString)
                .font(OAType.display(countdownFontSize).monospacedDigit())
                .foregroundStyle(OAColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

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
                        .frame(maxWidth: .infinity, minHeight: OASize.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.glass)

                Button(action: onDelete) {
                    Label(L10n.actionDelete, systemImage: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(OAColor.danger)
                        .frame(maxWidth: .infinity, minHeight: OASize.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.glass)
            }
        }
        .padding(OASpacing.cardPadding)
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
                .frame(minWidth: 44, minHeight: OASize.minTouchTarget)
                .contentShape(RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .oaGlassPanel(cornerRadius: OARadius.chip)
        .accessibilityLabel(accessibilityLabel)
    }
}
