import SwiftUI

struct CreditsView: View {
    private let classicalRingtones = RingtoneCatalog.all.filter { $0.section == .classical }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.creditsMusicTitle)
                    .font(.headline)
                    .foregroundStyle(OAColor.textPrimary)

                Text(L10n.creditsMusicAttribution)
                    .font(.body)
                    .foregroundStyle(OAColor.textSecondary)

                Link(
                    L10n.creditsMusicCreatorLink,
                    destination: URL(string: "https://www.youtube.com/@ludandschlattsmusicalempor6746")!
                )
                .font(.body.weight(.semibold))

                Text(L10n.creditsMusicLicense)
                    .font(.body)
                    .foregroundStyle(OAColor.textSecondary)

                Link(
                    L10n.creditsMusicLicenseLink,
                    destination: URL(string: "https://creativecommons.org/licenses/by/3.0/")!
                )
                .font(.body.weight(.semibold))

                Text(L10n.creditsMusicChanges)
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
