import Foundation

enum RingtoneSection: String, CaseIterable, Codable, Sendable {
    case classical
    case classicAlarms
    case dawn
    case nature
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
        Ringtone(
            id: "classic.placeholder",
            displayNameKey: "ringtone_classic_placeholder",
            section: .classicAlarms,
            excerptFileName: "ringtone_classic_placeholder.caf",
            fullTrackFileName: "ringtone_classic_placeholder.caf",
            excerptDuration: 20
        ),
        Ringtone(
            id: "dawn.placeholder",
            displayNameKey: "ringtone_dawn_placeholder",
            section: .dawn,
            excerptFileName: "ringtone_dawn_placeholder.caf",
            fullTrackFileName: "ringtone_dawn_placeholder.caf",
            excerptDuration: 20
        ),
        Ringtone(
            id: "nature.placeholder",
            displayNameKey: "ringtone_nature_placeholder",
            section: .nature,
            excerptFileName: "ringtone_nature_placeholder.caf",
            fullTrackFileName: "ringtone_nature_placeholder.caf",
            excerptDuration: 20
        ),
        Ringtone(
            id: "energetic.placeholder",
            displayNameKey: "ringtone_energetic_placeholder",
            section: .energetic,
            excerptFileName: "ringtone_energetic_placeholder.caf",
            fullTrackFileName: "ringtone_energetic_placeholder.caf",
            excerptDuration: 20
        )
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
