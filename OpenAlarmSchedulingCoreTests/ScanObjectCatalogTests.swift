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

    func testMatchPolicyAcceptsTopRankedLowConfidence() {
        // Field observation: clearly visible shoes classified at 4% absolute
        // confidence but top-ranked. Rank is the primary signal.
        XCTAssertTrue(ScanMatchPolicy.isMatch(rank: 1, confidence: 0.04))
        XCTAssertTrue(ScanMatchPolicy.isMatch(rank: 3, confidence: 0.02))
    }

    func testMatchPolicyAcceptsHighConfidenceRegardlessOfRank() {
        XCTAssertTrue(ScanMatchPolicy.isMatch(rank: 7, confidence: 0.15))
        XCTAssertTrue(ScanMatchPolicy.isMatch(rank: nil, confidence: 0.15))
    }

    func testMatchPolicyRejectsWeakOrLowRankedFrames() {
        XCTAssertFalse(ScanMatchPolicy.isMatch(rank: 4, confidence: 0.05))
        XCTAssertFalse(ScanMatchPolicy.isMatch(rank: 1, confidence: 0.01))
        XCTAssertFalse(ScanMatchPolicy.isMatch(rank: nil, confidence: 0.0))
    }
}
