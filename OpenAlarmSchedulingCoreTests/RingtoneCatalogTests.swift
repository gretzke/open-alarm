import XCTest
@testable import OpenAlarmSchedulingCore

final class RingtoneCatalogTests: XCTestCase {
    func testResolveFallsBackToDefaultForMissingOrUnknownIDs() {
        XCTAssertEqual(RingtoneCatalog.resolve(nil), RingtoneCatalog.defaultTone)
        XCTAssertEqual(RingtoneCatalog.resolve("garbage"), RingtoneCatalog.defaultTone)
    }

    func testResolveRoundTripsEveryCatalogID() {
        for ringtone in RingtoneCatalog.all {
            XCTAssertEqual(RingtoneCatalog.resolve(ringtone.id), ringtone)
        }
    }

    func testCatalogIDsAreUniqueAndDefaultAppearsExactlyOnce() {
        let ids = RingtoneCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.filter { $0 == RingtoneCatalog.defaultToneID }.count, 1)
    }

    func testSectionsContainExactlyTheExpectedRingtoneIDs() {
        XCTAssertEqual(ids(in: .classical), Set([
            "classical.valkyries",
            "classical.winter",
            "classical.bluedanube",
            "classical.cellosuite",
            "classical.russiandance"
        ]))
        XCTAssertEqual(ids(in: .classicAlarms), Set([
            "classic.default",
            "classic.twinbell",
            "classic.churchbells",
            "classic.ghanta",
            "classic.koshichime",
            "classic.bedsideclock",
            "classic.digitalalarm"
        ]))
        XCTAssertEqual(ids(in: .dawn), Set([
            "dawn.morning",
            "dawn.dreamer",
            "dawn.dreamculture",
            "dawn.lightthought",
            "dawn.deliberatethought",
            "dawn.magicscout",
            "dawn.wisdominthesun",
            "dawn.motions"
        ]))
        XCTAssertEqual(ids(in: .nature), Set([
            "nature.morningbirds",
            "nature.oceanwaves",
            "nature.rain",
            "nature.foreststream",
            "nature.rooster"
        ]))
        XCTAssertEqual(ids(in: .energetic), Set([
            "energetic.clouddancer",
            "energetic.voxelrevolution",
            "energetic.newerwave",
            "energetic.ravingenergy",
            "energetic.glitterblast",
            "energetic.hearwhattheysay",
            "energetic.avemarimba"
        ]))
    }

    func testNonDefaultEntriesHaveValidResourcesAndDurations() {
        for ringtone in RingtoneCatalog.all where !ringtone.isDefault {
            XCTAssertFalse(ringtone.excerptFileName.isEmpty)
            XCTAssertFalse(ringtone.fullTrackFileName.isEmpty)
            XCTAssertGreaterThan(ringtone.excerptDuration, 0)
        }
    }

    func testClassicAlarmTonesUseTheirExcerptAsTheFullTrack() {
        for ringtone in RingtoneCatalog.all where ringtone.section == .classicAlarms && !ringtone.isDefault {
            XCTAssertEqual(ringtone.excerptFileName, ringtone.fullTrackFileName)
        }
    }

    private func ids(in section: RingtoneSection) -> Set<String> {
        Set(RingtoneCatalog.sections.first { $0.0 == section }?.1.map(\.id) ?? [])
    }
}
