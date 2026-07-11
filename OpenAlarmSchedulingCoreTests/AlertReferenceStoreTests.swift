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
        let reference = AlertReference(
            expectedFireDate: Date(timeIntervalSinceReferenceDate: 123),
            ringtoneID: "dawn.placeholder"
        )

        store.record(reference, alarmKitID: keptID)
        store.record(reference, alarmKitID: staleID)
        XCTAssertEqual(store.reference(alarmKitID: keptID), reference)

        store.sweep(keeping: [keptID])
        XCTAssertEqual(store.reference(alarmKitID: keptID), reference)
        XCTAssertNil(store.reference(alarmKitID: staleID))

        store.clear(alarmKitID: keptID)
        XCTAssertNil(store.reference(alarmKitID: keptID))
    }

    func testResolverUsesPlausibleRecordedDate() {
        let now = date("2026-07-11T12:00:00Z")
        let recorded = AlertReference(expectedFireDate: date("2026-07-11T11:00:00Z"), ringtoneID: "classic.default")

        XCTAssertEqual(AlertReferenceResolver.alertStartedAt(
            recorded: recorded, alarmHour: 7, alarmMinute: 30, now: now, calendar: utcCalendar
        ), recorded.expectedFireDate)
    }

    func testResolverRejectsFutureAndStaleRecordedDates() {
        let now = date("2026-07-11T12:00:00Z")
        let expectedFallback = date("2026-07-11T07:30:00Z")
        let future = AlertReference(expectedFireDate: date("2026-07-11T12:01:00Z"), ringtoneID: "classic.default")
        let stale = AlertReference(expectedFireDate: date("2026-07-11T05:59:59Z"), ringtoneID: "classic.default")

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

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
