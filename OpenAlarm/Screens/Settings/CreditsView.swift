import SwiftUI

struct CreditsView: View {
    private let classicalRingtones = RingtoneCatalog.all.filter { $0.section == .classical }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.creditsClassicalTitle)
                    .font(.headline)
                    .foregroundStyle(OAColor.textPrimary)

                Text(L10n.creditsClassicalAttribution)
                    .font(.body)
                    .foregroundStyle(OAColor.textSecondary)

                Link(
                    L10n.creditsClassicalCreatorLink,
                    destination: URL(string: "https://www.youtube.com/@ludandschlattsmusicalempor6746")!
                )
                .font(.body.weight(.semibold))

                Text(L10n.creditsClassicalLicense)
                    .font(.body)
                    .foregroundStyle(OAColor.textSecondary)

                Link(
                    L10n.creditsClassicalLicenseLink,
                    destination: URL(string: "https://creativecommons.org/licenses/by/3.0/")!
                )
                .font(.body.weight(.semibold))

                Text(L10n.creditsClassicalChanges)
                    .font(.footnote)
                    .foregroundStyle(OAColor.textSecondary)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(classicalRingtones, id: \.id) { ringtone in
                        Text(LocalizedStringKey(ringtone.displayNameKey))
                            .font(.body)
                            .foregroundStyle(OAColor.textPrimary)
                    }
                }
                .padding(.top, 4)

                Divider()

                Text(L10n.creditsMusicTitle)
                    .font(.headline)
                    .foregroundStyle(OAColor.textPrimary)

                Text(L10n.creditsMusicAttribution)
                    .font(.body)
                    .foregroundStyle(OAColor.textSecondary)

                Link(
                    L10n.creditsMusicCreatorLink,
                    destination: URL(string: "https://incompetech.com/")!
                )
                .font(.body.weight(.semibold))

                Text(L10n.creditsMusicLicense)
                    .font(.body)
                    .foregroundStyle(OAColor.textSecondary)

                Link(
                    L10n.creditsMusicLicenseLink,
                    destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!
                )
                .font(.body.weight(.semibold))

                Text(L10n.creditsMusicMotions)
                    .font(.body)
                    .foregroundStyle(OAColor.textPrimary)

                Text(L10n.creditsMusicChanges)
                    .font(.footnote)
                    .foregroundStyle(OAColor.textSecondary)

                Divider()

                Text(L10n.creditsSoundsTitle)
                    .font(.headline)
                    .foregroundStyle(OAColor.textPrimary)

                Link(
                    L10n.creditsSoundsOceanWaves,
                    destination: URL(string: "https://creativecommons.org/licenses/by/3.0/")!
                )
                .font(.body.weight(.semibold))

                Link(
                    L10n.creditsSoundsRainOnLeaves,
                    destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!
                )
                .font(.body.weight(.semibold))

                Text(L10n.creditsSoundsCourtesy)
                    .font(.footnote)
                    .foregroundStyle(OAColor.textSecondary)
            }
            .padding(OASpacing.cardPadding)
            .oaGlassCard()
            .padding(OASpacing.screenMargin)
        }
        .background(OAColor.background.ignoresSafeArea())
        .navigationTitle(L10n.settingsCreditsTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}
