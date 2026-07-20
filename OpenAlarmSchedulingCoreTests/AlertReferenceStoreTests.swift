import XCTest
@testable import OpenAlarmSchedulingCore

final class AlertReferenceStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let suiteName = "AlertReferenceStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRecordReadClearAndSweep() {
        let store = AlertReferenceStore(defaults: defaults)
        let keptID = UUID()
        let staleID = UUID()
        let parentID = UUID()
        let reference = AlertReference(
            expectedFireDate: Date(timeIntervalSinceReferenceDate: 123),
            ringtoneID: "dawn.placeholder",
            parentAlarmID: parentID
        )

        store.record(reference, alarmKitID: keptID)
        store.record(reference, alarmKitID: staleID)
        XCTAssertEqual(store.reference(alarmKitID: keptID), reference)

        store.sweep(keeping: [keptID], existingParentAlarmIDs: [parentID])
        XCTAssertEqual(store.reference(alarmKitID: keptID), reference)
        XCTAssertNil(store.reference(alarmKitID: staleID))

        store.clear(alarmKitID: keptID)
        XCTAssertNil(store.reference(alarmKitID: keptID))
    }

    func testResolverUsesPlausibleRecordedDate() {
        let now = date("2026-07-11T12:00:00Z")
        let recorded = AlertReference(
            expectedFireDate: date("2026-07-11T11:00:00Z"),
            ringtoneID: "classic.default",
            parentAlarmID: UUID()
        )

        XCTAssertEqual(AlertReferenceResolver.alertStartedAt(
            recorded: recorded, alarmHour: 7, alarmMinute: 30, now: now, calendar: utcCalendar
        ), recorded.expectedFireDate)
    }

    func testResolverRejectsFutureAndStaleRecordedDates() {
        let now = date("2026-07-11T12:00:00Z")
        let expectedFallback = date("2026-07-11T07:30:00Z")
        let future = AlertReference(
            expectedFireDate: date("2026-07-11T12:01:00Z"),
            ringtoneID: "classic.default",
            parentAlarmID: UUID()
        )
        let stale = AlertReference(
            expectedFireDate: date("2026-07-11T05:59:59Z"),
            ringtoneID: "classic.default",
            parentAlarmID: UUID()
        )

        XCTAssertEqual(AlertReferenceResolver.alertStartedAt(
            recorded: future, alarmHour: 7, alarmMinute: 30, now: now, calendar: utcCalendar
        ), expectedFallback)
        XCTAssertEqual(AlertReferenceResolver.alertStartedAt(
            recorded: stale, alarmHour: 7, alarmMinute: 30, now: now, calendar: utcCalendar
        ), expectedFallback)
    }

    func testResolverFallsBackToTodayOrYesterdayAndNowForInvalidTime() {
        let now = date("2026-07-11T12:00:00Z")
        XCTAssertEqual(AlertReferenceResolver.alertStartedAt(
            recorded: nil, alarmHour: 7, alarmMinute: 30, now: now, calendar: utcCalendar
        ), date("2026-07-11T07:30:00Z"))
        XCTAssertEqual(AlertReferenceResolver.alertStartedAt(
            recorded: nil, alarmHour: 18, alarmMinute: 30, now: now, calendar: utcCalendar
        ), date("2026-07-10T18:30:00Z"))
        XCTAssertEqual(AlertReferenceResolver.alertStartedAt(
            recorded: nil, alarmHour: 24, alarmMinute: 0, now: now, calendar: utcCalendar
        ), now)
    }

    func testSweepRetainsRecentPastReferenceForLiveParent() {
        let now = date("2026-07-21T12:00:00Z")
        let parentID = UUID()
        let bridgeID = UUID()
        let reference = AlertReference(
            expectedFireDate: now.addingTimeInterval(-60),
            ringtoneID: "classic.default",
            parentAlarmID: parentID
        )
        let store = AlertReferenceStore(defaults: defaults)
        store.record(reference, alarmKitID: bridgeID)

        store.sweep(keeping: [], existingParentAlarmIDs: [parentID], now: now)

        XCTAssertEqual(store.reference(alarmKitID: bridgeID), reference)
    }

    func testSweepDropsExpiredAndFutureNonActiveReferences() {
        let now = date("2026-07-21T12:00:00Z")
        let parentID = UUID()
        let expiredID = UUID()
        let futureID = UUID()
        let store = AlertReferenceStore(defaults: defaults)
        store.record(
            AlertReference(
                expectedFireDate: now.addingTimeInterval(-SchedulingConstants.referenceRetentionSeconds - 1),
                ringtoneID: "classic.default",
                parentAlarmID: parentID
            ),
            alarmKitID: expiredID
        )
        store.record(
            AlertReference(
                expectedFireDate: now.addingTimeInterval(60),
                ringtoneID: "classic.default",
                parentAlarmID: parentID
            ),
            alarmKitID: futureID
        )

        store.sweep(keeping: [], existingParentAlarmIDs: [parentID], now: now)

        XCTAssertNil(store.reference(alarmKitID: expiredID))
        XCTAssertNil(store.reference(alarmKitID: futureID))
    }

    func testSweepDropsLegacyParentlessReferenceAndOptionalFieldDecodes() throws {
        let now = date("2026-07-21T12:00:00Z")
        let legacyID = UUID()
        let legacy = LegacyAlertReference(expectedFireDate: now.addingTimeInterval(-60), ringtoneID: "classic.default")
        let key = OpenAlarmSharedDefaults.Key.alertReferencePrefix + legacyID.uuidString
        defaults.set(try JSONEncoder().encode(legacy), forKey: key)
        let store = AlertReferenceStore(defaults: defaults)

        XCTAssertNil(store.reference(alarmKitID: legacyID)?.parentAlarmID)
        store.sweep(keeping: [], existingParentAlarmIDs: [UUID()], now: now)

        XCTAssertNil(store.reference(alarmKitID: legacyID))
    }

    func testSweepKeepsUndecodableActiveKey() {
        // An active registration's entry may be mid-replacement by an intent
        // in another process; an undecodable snapshot must never delete it.
        let activeID = UUID()
        let key = OpenAlarmSharedDefaults.Key.alertReferencePrefix + activeID.uuidString
        defaults.set(Data("garbage".utf8), forKey: key)
        let store = AlertReferenceStore(defaults: defaults)

        store.sweep(keeping: [activeID], existingParentAlarmIDs: [], now: date("2026-07-21T12:00:00Z"))

        XCTAssertNotNil(defaults.data(forKey: key))
    }

    func testParentKeyedBackstopOverwritePreservesParentResolution() {
        let parentID = UUID()
        let store = AlertReferenceStore(defaults: defaults)
        store.record(
            AlertReference(
                expectedFireDate: .now.addingTimeInterval(-60),
                ringtoneID: "classic.default",
                parentAlarmID: parentID
            ),
            alarmKitID: parentID
        )
        store.record(
            AlertReference(
                expectedFireDate: .now.addingTimeInterval(30),
                ringtoneID: "classic.default",
                parentAlarmID: parentID
            ),
            alarmKitID: parentID
        )

        XCTAssertEqual(store.reference(alarmKitID: parentID)?.parentAlarmID, parentID)
    }

    private struct LegacyAlertReference: Codable {
        let expectedFireDate: Date
        let ringtoneID: String
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
