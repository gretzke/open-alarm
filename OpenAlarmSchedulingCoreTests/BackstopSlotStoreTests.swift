import XCTest
@testable import OpenAlarmSchedulingCore

final class BackstopSlotStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "openalarm-backstop-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSetLookupReverseLookupAndClearRoundTrip() {
        let parentID = UUID()
        let backstopID = UUID()

        BackstopSlotStore.set(backstopID: backstopID, forParent: parentID, defaults: defaults)

        XCTAssertEqual(BackstopSlotStore.backstopID(forParent: parentID, defaults: defaults), backstopID)
        XCTAssertEqual(BackstopSlotStore.parentID(forBackstop: backstopID, defaults: defaults), parentID)
        XCTAssertEqual(BackstopSlotStore.allSlots(defaults: defaults), [parentID: backstopID])
        XCTAssertEqual(BackstopSlotStore.clear(forParent: parentID, defaults: defaults), backstopID)
        XCTAssertNil(BackstopSlotStore.backstopID(forParent: parentID, defaults: defaults))
        XCTAssertNil(BackstopSlotStore.parentID(forBackstop: backstopID, defaults: defaults))
        XCTAssertEqual(BackstopSlotStore.allSlots(defaults: defaults), [:])
    }

    func testIntentDiagnosticsRingBufferCapsAtThreeHundredEntries() {
        IntentDiagnostics.clear(defaults: defaults)

        for index in 0..<305 {
            IntentDiagnostics.log("entry-\(index)", defaults: defaults)
        }

        let entries = IntentDiagnostics.entries(defaults: defaults)
        XCTAssertEqual(entries.count, 300)
        XCTAssertTrue(entries.first?.contains("entry-5") == true)
        XCTAssertTrue(entries.last?.contains("entry-304") == true)
    }
}
