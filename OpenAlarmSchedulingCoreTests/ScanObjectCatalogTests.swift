import XCTest
@testable import OpenAlarmSchedulingCore

final class ScanObjectCatalogTests: XCTestCase {
    func testEntriesAreNonEmptyAndHaveUniqueIdentifiers() {
        XCTAssertFalse(ScanObjectCatalog.entries.isEmpty)
        XCTAssertEqual(
            Set(ScanObjectCatalog.entries.map(\.id)).count,
            ScanObjectCatalog.entries.count
        )
    }

    func testLookupReturnsMatchingEntryAndIsNilSafe() {
        for entry in ScanObjectCatalog.entries {
            XCTAssertEqual(ScanObjectCatalog.entry(for: entry.id), entry)
            XCTAssertFalse(entry.systemImage.isEmpty)
        }

        XCTAssertNil(ScanObjectCatalog.entry(for: "does_not_exist"))
    }
}
