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

    func testNonDefaultEntriesHaveValidResourcesAndDurations() {
        for ringtone in RingtoneCatalog.all where !ringtone.isDefault {
            XCTAssertFalse(ringtone.excerptFileName.isEmpty)
            XCTAssertFalse(ringtone.fullTrackFileName.isEmpty)
            XCTAssertGreaterThan(ringtone.excerptDuration, 0)
            if ringtone.section != .classical {
                XCTAssertEqual(ringtone.fullTrackFileName, ringtone.excerptFileName)
            }
        }
    }
}
