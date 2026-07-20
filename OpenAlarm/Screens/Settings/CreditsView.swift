import SwiftUI

struct CreditsView: View {
    @EnvironmentObject private var alarmStore: AlarmStore
    @State private var unlockTapCount = 0
    @State private var showsAlreadyUnlocked = false

    private struct Credit: Identifiable {
        let id: String
        let creator: String
        let licenseName: String
        let sourceURL: URL
        let licenseURL: URL

        var displayNameKey: String {
            RingtoneCatalog.all.first(where: { $0.id == id })?.displayNameKey ?? id
        }

        init(
            _ id: String,
            creator: String,
            license: String,
            source: String,
            licenseURL: String
        ) {
            self.id = id
            self.creator = creator
            self.licenseName = license
            self.sourceURL = URL(string: source)!
            self.licenseURL = URL(string: licenseURL)!
        }
    }

    private let classicalCredits = [
        Credit(
            "classical.valkyries",
            creator: "Lud and Schlatt's Musical Emporium / Philip Milman",
            license: "CC BY 3.0",
            source: "https://www.youtube.com/watch?v=uNkRW_9pHRQ",
            licenseURL: "https://creativecommons.org/licenses/by/3.0/"
        ),
        Credit(
            "classical.winter",
            creator: "Lud and Schlatt's Musical Emporium / Philip Milman",
            license: "CC BY 3.0",
            source: "https://www.youtube.com/watch?v=VBSP75pr2bg",
            licenseURL: "https://creativecommons.org/licenses/by/3.0/"
        ),
        Credit(
            "classical.bluedanube",
            creator: "Lud and Schlatt's Musical Emporium / Philip Milman",
            license: "CC BY 3.0",
            source: "https://www.youtube.com/watch?v=K8Onx1118x8",
            licenseURL: "https://creativecommons.org/licenses/by/3.0/"
        ),
        Credit(
            "classical.cellosuite",
            creator: "Lud and Schlatt's Musical Emporium / Philip Milman",
            license: "CC BY 3.0",
            source: "https://www.youtube.com/watch?v=e_J14fbBluE",
            licenseURL: "https://creativecommons.org/licenses/by/3.0/"
        ),
        Credit(
            "classical.russiandance",
            creator: "Lud and Schlatt's Musical Emporium / Philip Milman",
            license: "CC BY 3.0",
            source: "https://www.youtube.com/watch?v=CcHo03GzMN8",
            licenseURL: "https://creativecommons.org/licenses/by/3.0/"
        )
    ]

    private let musicCredits = [
        Credit(
            "dawn.morning",
            creator: "Kevin MacLeod",
            license: "CC BY 4.0",
            source: "https://incompetech.com/music/royalty-free/index.html?isrc=USUAN2300003&Search=Search",
            licenseURL: "https://creativecommons.org/licenses/by/4.0/"
        ),
        Credit(
            "dawn.dreamer",
            creator: "Kevin MacLeod",
            license: "CC BY 4.0",
            source: "https://incompetech.com/music/royalty-free/index.html?isrc=USUAN1600043&Search=Search",
            licenseURL: "https://creativecommons.org/licenses/by/4.0/"
        ),
        Credit(
            "dawn.dreamculture",
            creator: "Kevin MacLeod",
            license: "CC BY 4.0",
            source: "https://incompetech.com/music/royalty-free/index.html?isrc=USUAN1300046&Search=Search",
            licenseURL: "https://creativecommons.org/licenses/by/4.0/"
        ),
        Credit(
            "dawn.lightthought",
            creator: "Kevin MacLeod",
            license: "CC BY 4.0",
            source: "https://incompetech.com/music/royalty-free/index.html?isrc=USUAN1200006&Search=Search",
            licenseURL: "https://creativecommons.org/licenses/by/4.0/"
        ),
        Credit(
            "dawn.deliberatethought",
            creator: "Kevin MacLeod",
            license: "CC BY 4.0",
            source: "https://incompetech.com/music/royalty-free/index.html?isrc=USUAN1100261&Search=Search",
            licenseURL: "https://creativecommons.org/licenses/by/4.0/"
        ),
        Credit(
            "dawn.magicscout",
            creator: "Kevin MacLeod",
            license: "CC BY 4.0",
            source: "https://incompetech.com/wordpress/2018/10/breakfast-in-the-solarium-mlord/",
            licenseURL: "https://creativecommons.org/licenses/by/4.0/"
        ),
        Credit(
            "dawn.wisdominthesun",
            creator: "Kevin MacLeod",
            license: "CC0",
            source: "https://web.archive.org/web/20250121173813/https://freepd.com/misc.php",
            licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/"
        ),
        Credit(
            "dawn.motions",
            creator: "Rafael Krux",
            license: "CC0",
            source: "https://web.archive.org/web/20250106221458/https://freepd.com/upbeat.php",
            licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/"
        ),
        Credit(
            "energetic.clouddancer",
            creator: "Kevin MacLeod",
            license: "CC BY 4.0",
            source: "https://incompetech.com/music/royalty-free/index.html?isrc=USUAN2300007&Search=Search",
            licenseURL: "https://creativecommons.org/licenses/by/4.0/"
        ),
        Credit(
            "energetic.voxelrevolution",
            creator: "Kevin MacLeod",
            license: "CC BY 4.0",
            source: "https://incompetech.com/music/royalty-free/index.html?isrc=USUAN2000025&Search=Search",
            licenseURL: "https://creativecommons.org/licenses/by/4.0/"
        ),
        Credit(
            "energetic.newerwave",
            creator: "Kevin MacLeod",
            license: "CC BY 4.0",
            source: "https://incompetech.com/music/royalty-free/index.html?isrc=USUAN2000024&Search=Search",
            licenseURL: "https://creativecommons.org/licenses/by/4.0/"
        ),
        Credit(
            "energetic.ravingenergy",
            creator: "Kevin MacLeod",
            license: "CC BY 4.0",
            source: "https://incompetech.com/music/royalty-free/index.html?isrc=USUAN1900012&Search=Search",
            licenseURL: "https://creativecommons.org/licenses/by/4.0/"
        ),
        Credit(
            "energetic.glitterblast",
            creator: "Kevin MacLeod",
            license: "CC BY 4.0",
            source: "https://incompetech.com/music/royalty-free/index.html?isrc=USUAN1900001&Search=Search",
            licenseURL: "https://creativecommons.org/licenses/by/4.0/"
        ),
        Credit(
            "energetic.hearwhattheysay",
            creator: "Kevin MacLeod",
            license: "CC0",
            source: "https://web.archive.org/web/20241217205507/https://freepd.com/electronic.php",
            licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/"
        ),
        Credit(
            "energetic.avemarimba",
            creator: "Kevin MacLeod",
            license: "CC BY 3.0",
            source: "https://commons.wikimedia.org/wiki/File:Ave_Marimba_(ISRC_USUAN1700024).mp3",
            licenseURL: "https://creativecommons.org/licenses/by/3.0/"
        )
    ]

    private let soundCredits = [
        Credit(
            "nature.morningbirds",
            creator: "Joseph Sardin",
            license: "CC0",
            source: "https://commons.wikimedia.org/wiki/File:R%C3%A9veil_des_oiseaux.ogg",
            licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/"
        ),
        Credit(
            "nature.oceanwaves",
            creator: "Luftrum",
            license: "CC BY 3.0",
            source: "https://commons.wikimedia.org/wiki/File:Oceanwavescrushing.ogg",
            licenseURL: "https://creativecommons.org/licenses/by/3.0/"
        ),
        Credit(
            "nature.rain",
            creator: "Gravity Sound",
            license: "CC BY 4.0",
            source: "https://commons.wikimedia.org/wiki/File:Rain_on_leaves_(Gravity_Sound).wav",
            licenseURL: "https://creativecommons.org/licenses/by/4.0/"
        ),
        Credit(
            "nature.foreststream",
            creator: "cher1101",
            license: "CC0",
            source: "https://freesound.org/people/cher1101/sounds/671947/",
            licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/"
        ),
        Credit(
            "nature.rooster",
            creator: "Garuda1982",
            license: "CC0",
            source: "https://freesound.org/people/Garuda1982/sounds/627335/",
            licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/"
        ),
        Credit(
            "classic.twinbell",
            creator: "cryptidcat",
            license: "CC0",
            source: "https://freesound.org/people/cryptidcat/sounds/743963/",
            licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/"
        ),
        Credit(
            "classic.churchbells",
            creator: "natalie / pdsounds.org",
            license: "Public domain",
            source: "https://commons.wikimedia.org/wiki/File:Church_bells_-_Leverkusen,_2007.oga",
            licenseURL: "https://creativecommons.org/publicdomain/mark/1.0/"
        ),
        Credit(
            "classic.ghanta",
            creator: "the_very_Real_Horst",
            license: "CC0",
            source: "https://commons.wikimedia.org/wiki/File:274316_the-very-real-horst_ghanta-leather-mallet-2015-05-16.wav",
            licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/"
        ),
        Credit(
            "classic.koshichime",
            creator: "Membeth",
            license: "CC0",
            source: "https://commons.wikimedia.org/wiki/File:Windglockenspiel.Koshi.ogg",
            licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/"
        ),
        Credit(
            "classic.bedsideclock",
            creator: "OpenAlarm project — synthesized tone",
            license: "CC0",
            source: "https://github.com/gretzke/open-alarm/blob/main/OpenAlarm/Resources/Ringtones/SOURCES.md#project-generated-digital-alarm-tones",
            licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/"
        ),
        Credit(
            "classic.digitalalarm",
            creator: "OpenAlarm project — synthesized tone",
            license: "CC0",
            source: "https://github.com/gretzke/open-alarm/blob/main/OpenAlarm/Resources/Ringtones/SOURCES.md#project-generated-digital-alarm-tones",
            licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/"
        )
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let unlockStatusText {
                    Text(unlockStatusText)
                        .font(.footnote)
                        .foregroundStyle(OAColor.textSecondary)
                }

                Text(L10n.creditsIntro)
                    .font(.body)
                    .foregroundStyle(OAColor.textSecondary)

                Link(
                    L10n.creditsCodeLicense,
                    destination: URL(string: "https://github.com/gretzke/open-alarm/blob/main/LICENSE")!
                )
                .font(.body.weight(.semibold))

                Divider()

                creditSection(title: L10n.creditsClassicalTitle, credits: classicalCredits)
                Divider()
                creditSection(title: L10n.creditsMusicTitle, credits: musicCredits)
                Divider()
                creditSection(title: L10n.creditsSoundsTitle, credits: soundCredits)

                Text(L10n.creditsChanges)
                    .font(.footnote)
                    .foregroundStyle(OAColor.textSecondary)

                Link(
                    L10n.creditsFullLedger,
                    destination: URL(string: "https://github.com/gretzke/open-alarm/blob/main/OpenAlarm/Resources/Ringtones/SOURCES.md")!
                )
                .font(.footnote.weight(.semibold))
            }
            .padding(OASpacing.cardPadding)
            .oaGlassCard()
            .padding(OASpacing.screenMargin)
        }
        .background(OAColor.background.ignoresSafeArea())
        .navigationTitle(L10n.settingsCreditsTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(L10n.settingsCreditsTitle)
                    .font(.headline)
                    .foregroundStyle(OAColor.textPrimary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: handleTitleTap)
                    .accessibilityAddTraits(.isButton)
            }
        }
        .onDisappear {
            unlockTapCount = 0
            showsAlreadyUnlocked = false
        }
    }

    private var unlockStatusText: String? {
        if showsAlreadyUnlocked {
            return L10n.creditsTestingModeAlreadyUnlocked
        }

        if unlockTapCount >= 10 {
            return L10n.creditsTestingModeUnlocked
        }

        guard unlockTapCount >= 5 else {
            return nil
        }

        return L10n.creditsTestingModeUnlockCountdown(10 - unlockTapCount)
    }

    private func handleTitleTap() {
        guard !alarmStore.testingSectionUnlocked else {
            showsAlreadyUnlocked = true
            announceUnlockStatus()
            return
        }

        unlockTapCount += 1

        if unlockTapCount == 10 {
            alarmStore.updateTestingSectionUnlocked(true)
            Haptics.success()
        } else if unlockTapCount >= 5 {
            Haptics.impact(.light)
        }
        announceUnlockStatus()
    }

    /// The status line sits outside the focused toolbar element, so VoiceOver
    /// users would otherwise get no feedback while tapping.
    private func announceUnlockStatus() {
        guard let unlockStatusText else { return }
        AccessibilityNotification.Announcement(unlockStatusText).post()
    }

    private func creditSection(title: LocalizedStringKey, credits: [Credit]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(OAColor.textPrimary)

            ForEach(credits) { credit in
                VStack(alignment: .leading, spacing: 4) {
                    Link(destination: credit.sourceURL) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(LocalizedStringKey(credit.displayNameKey))
                                .multilineTextAlignment(.leading)
                            Image(systemName: "arrow.up.right")
                                .font(.caption2.weight(.bold))
                        }
                    }
                    .font(.body.weight(.semibold))

                    Text(verbatim: credit.creator)
                        .font(.footnote)
                        .foregroundStyle(OAColor.textSecondary)

                    Link(destination: credit.licenseURL) {
                        Text(verbatim: credit.licenseName)
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        }
    }
}
