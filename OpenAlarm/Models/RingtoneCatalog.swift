import Foundation

// Case order defines the picker's section order.
enum RingtoneSection: String, CaseIterable, Codable, Sendable {
    case classicAlarms
    case nature
    case classical
    case dawn
    case energetic

    var displayNameKey: String {
        switch self {
        case .classical: "ringtone_section_classical"
        case .classicAlarms: "ringtone_section_classic_alarms"
        case .dawn: "ringtone_section_dawn"
        case .nature: "ringtone_section_nature"
        case .energetic: "ringtone_section_energetic"
        }
    }
}

struct Ringtone: Equatable, Sendable {
    let id: String
    let displayNameKey: String
    let section: RingtoneSection
    let excerptFileName: String
    let fullTrackFileName: String
    let excerptDuration: TimeInterval

    var isDefault: Bool {
        id == RingtoneCatalog.defaultToneID
    }
}

enum RingtoneCatalog {
    static let defaultToneID = "classic.default"

    static let all: [Ringtone] = [
        Ringtone(
            id: defaultToneID,
            displayNameKey: "ringtone_classic_default",
            section: .classicAlarms,
            excerptFileName: "",
            fullTrackFileName: "",
            excerptDuration: 0
        ),
        Ringtone(
            id: "classical.valkyries",
            displayNameKey: "ringtone_classical_valkyries",
            section: .classical,
            excerptFileName: "ringtone_classical_valkyries.caf",
            fullTrackFileName: "ringtone_classical_valkyries_full.m4a",
            excerptDuration: 28.993
        ),
        Ringtone(
            id: "classical.winter",
            displayNameKey: "ringtone_classical_winter",
            section: .classical,
            excerptFileName: "ringtone_classical_winter.caf",
            fullTrackFileName: "ringtone_classical_winter_full.m4a",
            excerptDuration: 28.993
        ),
        Ringtone(
            id: "classical.bluedanube",
            displayNameKey: "ringtone_classical_bluedanube",
            section: .classical,
            excerptFileName: "ringtone_classical_bluedanube.caf",
            fullTrackFileName: "ringtone_classical_bluedanube_full.m4a",
            excerptDuration: 28.993
        ),
        Ringtone(
            id: "classical.cellosuite",
            displayNameKey: "ringtone_classical_cellosuite",
            section: .classical,
            excerptFileName: "ringtone_classical_cellosuite.caf",
            fullTrackFileName: "ringtone_classical_cellosuite_full.m4a",
            excerptDuration: 28.993
        ),
        Ringtone(
            id: "classical.russiandance",
            displayNameKey: "ringtone_classical_russiandance",
            section: .classical,
            excerptFileName: "ringtone_classical_russiandance.caf",
            fullTrackFileName: "ringtone_classical_russiandance_full.m4a",
            excerptDuration: 28.993
        ),
        Ringtone(id: "classic.twinbell", displayNameKey: "ringtone_classic_twinbell", section: .classicAlarms, excerptFileName: "ringtone_classic_twinbell.caf", fullTrackFileName: "ringtone_classic_twinbell.caf", excerptDuration: 29.0),
        Ringtone(id: "classic.churchbells", displayNameKey: "ringtone_classic_churchbells", section: .classicAlarms, excerptFileName: "ringtone_classic_churchbells.caf", fullTrackFileName: "ringtone_classic_churchbells.caf", excerptDuration: 29.0),
        Ringtone(id: "classic.ghanta", displayNameKey: "ringtone_classic_ghanta", section: .classicAlarms, excerptFileName: "ringtone_classic_ghanta.caf", fullTrackFileName: "ringtone_classic_ghanta.caf", excerptDuration: 29.0),
        Ringtone(id: "classic.koshichime", displayNameKey: "ringtone_classic_koshichime", section: .classicAlarms, excerptFileName: "ringtone_classic_koshichime.caf", fullTrackFileName: "ringtone_classic_koshichime.caf", excerptDuration: 28.989),
        Ringtone(id: "classic.bedsideclock", displayNameKey: "ringtone_classic_bedsideclock", section: .classicAlarms, excerptFileName: "ringtone_classic_bedsideclock.caf", fullTrackFileName: "ringtone_classic_bedsideclock.caf", excerptDuration: 11.04),
        Ringtone(id: "classic.digitalalarm", displayNameKey: "ringtone_classic_digitalalarm", section: .classicAlarms, excerptFileName: "ringtone_classic_digitalalarm.caf", fullTrackFileName: "ringtone_classic_digitalalarm.caf", excerptDuration: 4.56),
        Ringtone(id: "dawn.morning", displayNameKey: "ringtone_dawn_morning", section: .dawn, excerptFileName: "ringtone_dawn_morning.caf", fullTrackFileName: "ringtone_dawn_morning_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "dawn.dreamer", displayNameKey: "ringtone_dawn_dreamer", section: .dawn, excerptFileName: "ringtone_dawn_dreamer.caf", fullTrackFileName: "ringtone_dawn_dreamer_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "dawn.dreamculture", displayNameKey: "ringtone_dawn_dreamculture", section: .dawn, excerptFileName: "ringtone_dawn_dreamculture.caf", fullTrackFileName: "ringtone_dawn_dreamculture_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "dawn.lightthought", displayNameKey: "ringtone_dawn_lightthought", section: .dawn, excerptFileName: "ringtone_dawn_lightthought.caf", fullTrackFileName: "ringtone_dawn_lightthought_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "dawn.deliberatethought", displayNameKey: "ringtone_dawn_deliberatethought", section: .dawn, excerptFileName: "ringtone_dawn_deliberatethought.caf", fullTrackFileName: "ringtone_dawn_deliberatethought_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "dawn.magicscout", displayNameKey: "ringtone_dawn_magicscout", section: .dawn, excerptFileName: "ringtone_dawn_magicscout.caf", fullTrackFileName: "ringtone_dawn_magicscout_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "dawn.wisdominthesun", displayNameKey: "ringtone_dawn_wisdominthesun", section: .dawn, excerptFileName: "ringtone_dawn_wisdominthesun.caf", fullTrackFileName: "ringtone_dawn_wisdominthesun_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "dawn.motions", displayNameKey: "ringtone_dawn_motions", section: .dawn, excerptFileName: "ringtone_dawn_motions.caf", fullTrackFileName: "ringtone_dawn_motions_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "nature.morningbirds", displayNameKey: "ringtone_nature_morningbirds", section: .nature, excerptFileName: "ringtone_nature_morningbirds.caf", fullTrackFileName: "ringtone_nature_morningbirds_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "nature.oceanwaves", displayNameKey: "ringtone_nature_oceanwaves", section: .nature, excerptFileName: "ringtone_nature_oceanwaves.caf", fullTrackFileName: "ringtone_nature_oceanwaves_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "nature.rain", displayNameKey: "ringtone_nature_rain", section: .nature, excerptFileName: "ringtone_nature_rain.caf", fullTrackFileName: "ringtone_nature_rain_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "nature.foreststream", displayNameKey: "ringtone_nature_foreststream", section: .nature, excerptFileName: "ringtone_nature_foreststream.caf", fullTrackFileName: "ringtone_nature_foreststream_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "nature.rooster", displayNameKey: "ringtone_nature_rooster", section: .nature, excerptFileName: "ringtone_nature_rooster.caf", fullTrackFileName: "ringtone_nature_rooster_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "energetic.clouddancer", displayNameKey: "ringtone_energetic_clouddancer", section: .energetic, excerptFileName: "ringtone_energetic_clouddancer.caf", fullTrackFileName: "ringtone_energetic_clouddancer_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "energetic.voxelrevolution", displayNameKey: "ringtone_energetic_voxelrevolution", section: .energetic, excerptFileName: "ringtone_energetic_voxelrevolution.caf", fullTrackFileName: "ringtone_energetic_voxelrevolution_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "energetic.newerwave", displayNameKey: "ringtone_energetic_newerwave", section: .energetic, excerptFileName: "ringtone_energetic_newerwave.caf", fullTrackFileName: "ringtone_energetic_newerwave_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "energetic.ravingenergy", displayNameKey: "ringtone_energetic_ravingenergy", section: .energetic, excerptFileName: "ringtone_energetic_ravingenergy.caf", fullTrackFileName: "ringtone_energetic_ravingenergy_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "energetic.glitterblast", displayNameKey: "ringtone_energetic_glitterblast", section: .energetic, excerptFileName: "ringtone_energetic_glitterblast.caf", fullTrackFileName: "ringtone_energetic_glitterblast_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "energetic.hearwhattheysay", displayNameKey: "ringtone_energetic_hearwhattheysay", section: .energetic, excerptFileName: "ringtone_energetic_hearwhattheysay.caf", fullTrackFileName: "ringtone_energetic_hearwhattheysay_full.m4a", excerptDuration: 29.0),
        Ringtone(id: "energetic.avemarimba", displayNameKey: "ringtone_energetic_avemarimba", section: .energetic, excerptFileName: "ringtone_energetic_avemarimba.caf", fullTrackFileName: "ringtone_energetic_avemarimba_full.m4a", excerptDuration: 29.0)
    ]

    static var sections: [(RingtoneSection, [Ringtone])] {
        RingtoneSection.allCases.map { section in
            (section, all.filter { $0.section == section })
        }
    }

    static func resolve(_ id: String?) -> Ringtone {
        guard let id, let ringtone = all.first(where: { $0.id == id }) else {
            return defaultTone
        }
        return ringtone
    }

    static var defaultTone: Ringtone {
        // This is an invariant of the static catalog above.
        all.first(where: { $0.id == defaultToneID })!
    }
}

enum RingtonePlayback {
    static func offset(
        alertStartedAt: Date,
        now: Date,
        excerptDuration: TimeInterval
    ) -> TimeInterval {
        let elapsed = now.timeIntervalSince(alertStartedAt)
        guard excerptDuration > 0, elapsed >= 0, elapsed <= 24 * 60 * 60 else {
            return 0
        }
        return elapsed.truncatingRemainder(dividingBy: excerptDuration)
    }
}
