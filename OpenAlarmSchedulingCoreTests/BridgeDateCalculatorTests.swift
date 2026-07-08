import XCTest
@testable import OpenAlarmSchedulingCore

final class BridgeDateCalculatorTests: XCTestCase {

    // Fixed calendar for deterministic tests
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    // Reference: Sunday 2026-03-15 at 22:00 EST
    // Next Mon = 2026-03-16, Wed = 2026-03-18, Fri = 2026-03-20
    private var referenceSunday10pm: Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 3
        comps.day = 15
        comps.hour = 22
        comps.minute = 0
        comps.second = 0
        return calendar.date(from: comps)!
    }

    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return calendar.date(from: comps)!
    }

    // MARK: - Test 1: Skip-next with Mon/Wed/Fri alarm

    func testSkipNextMonWedFri() {
        // Alarm at 7:00am on Mon/Wed/Fri
        // Reference = Sunday 2026-03-15 at 22:00
        // Next 6 occurrences: Mon 3/16, Wed 3/18, Fri 3/20, Mon 3/23, Wed 3/25, Fri 3/27
        // skip-next: skip Mon 3/16, bridges = Wed 3/18, Fri 3/20, Mon 3/23, Wed 3/25, Fri 3/27
        // restoreAnchorDate = Mon 3/16 7am

        let result = BridgeDateCalculator.bridgeDates(
            hour: 7,
            minute: 0,
            repeatDays: [.monday, .wednesday, .friday],
            overrideKind: .skipNext,
            modifiedTime: nil,
            referenceDate: referenceSunday10pm,
            calendar: calendar
        )

        XCTAssertEqual(result.bridgeDates.count, 5)

        let expectedBridges: [Date] = [
            date(year: 2026, month: 3, day: 18, hour: 7, minute: 0), // Wed
            date(year: 2026, month: 3, day: 20, hour: 7, minute: 0), // Fri
            date(year: 2026, month: 3, day: 23, hour: 7, minute: 0), // Mon
            date(year: 2026, month: 3, day: 25, hour: 7, minute: 0), // Wed
            date(year: 2026, month: 3, day: 27, hour: 7, minute: 0), // Fri
        ]
        XCTAssertEqual(result.bridgeDates, expectedBridges)

        let expectedAnchor = date(year: 2026, month: 3, day: 16, hour: 7, minute: 0) // Mon
        XCTAssertEqual(result.restoreAnchorDate, expectedAnchor)
    }

    // MARK: - Test 2: Modify-next earlier (7am → 6:30am)

    func testModifyNextEarlier() {
        // Alarm at 7:00am on Mon/Wed/Fri, modify first occurrence to 6:30am
        // First canonical occurrence: Mon 3/16 7am
        // Modified: Mon 3/16 6:30am
        // Bridge[0] = Mon 3/16 6:30am (modified)
        // Bridge[1..4] = Wed 3/18, Fri 3/20, Mon 3/23, Wed 3/25 (canonical 7am)
        // restoreAnchorDate = Mon 3/16 7am so the suppressed same-day canonical slot
        // has passed before the schedule can be restored.

        let result = BridgeDateCalculator.bridgeDates(
            hour: 7,
            minute: 0,
            repeatDays: [.monday, .wednesday, .friday],
            overrideKind: .modifyNext,
            modifiedTime: (hour: 6, minute: 30),
            referenceDate: referenceSunday10pm,
            calendar: calendar
        )

        XCTAssertEqual(result.bridgeDates.count, 5)

        let expectedBridge0 = date(year: 2026, month: 3, day: 16, hour: 6, minute: 30)
        XCTAssertEqual(result.bridgeDates[0], expectedBridge0, "First bridge should be modified time on Monday")

        let expectedBridge1 = date(year: 2026, month: 3, day: 18, hour: 7, minute: 0)
        XCTAssertEqual(result.bridgeDates[1], expectedBridge1, "Second bridge should be canonical time on Wednesday")

        let expectedBridge4 = date(year: 2026, month: 3, day: 25, hour: 7, minute: 0)
        XCTAssertEqual(result.bridgeDates[4], expectedBridge4, "Fifth bridge should be canonical time on Wed 3/25")

        let expectedAnchor = date(year: 2026, month: 3, day: 16, hour: 7, minute: 0)
        XCTAssertEqual(result.restoreAnchorDate, expectedAnchor)
    }

    // MARK: - Test 3: Modify-next later (7am → 8am)

    func testModifyNextLater() {
        // Alarm at 7:00am on Mon/Wed/Fri, modify first occurrence to 8:00am
        // First canonical occurrence: Mon 3/16 7am
        // Modified: Mon 3/16 8am
        // restoreAnchorDate = max(Mon 3/16 7am, Mon 3/16 8am) = Mon 3/16 8am

        let result = BridgeDateCalculator.bridgeDates(
            hour: 7,
            minute: 0,
            repeatDays: [.monday, .wednesday, .friday],
            overrideKind: .modifyNext,
            modifiedTime: (hour: 8, minute: 0),
            referenceDate: referenceSunday10pm,
            calendar: calendar
        )

        XCTAssertEqual(result.bridgeDates.count, 5)

        let expectedBridge0 = date(year: 2026, month: 3, day: 16, hour: 8, minute: 0)
        XCTAssertEqual(result.bridgeDates[0], expectedBridge0, "First bridge should be modified time on Monday")

        let expectedBridge1 = date(year: 2026, month: 3, day: 18, hour: 7, minute: 0)
        XCTAssertEqual(result.bridgeDates[1], expectedBridge1, "Second bridge should be canonical time on Wednesday")

        // Anchor = Mon 8am (modified > canonical 7am)
        let expectedAnchor = date(year: 2026, month: 3, day: 16, hour: 8, minute: 0)
        XCTAssertEqual(result.restoreAnchorDate, expectedAnchor)
    }

    func testModifyNextEarlierDailyRestoresAfterSameDayCanonicalSlot() {
        // Alarm at 9:00am every day, modify next occurrence to 8:00am.
        // The override must remain active through today's 9:00am canonical slot so the
        // original 9:00am on the modified day does not get restored back in early.
        let result = BridgeDateCalculator.bridgeDates(
            hour: 9,
            minute: 0,
            repeatDays: AlarmWeekday.allCases,
            overrideKind: .modifyNext,
            modifiedTime: (hour: 8, minute: 0),
            referenceDate: referenceSunday10pm,
            calendar: calendar
        )

        XCTAssertEqual(result.bridgeDates[0], date(year: 2026, month: 3, day: 16, hour: 8, minute: 0))
        XCTAssertEqual(result.bridgeDates[1], date(year: 2026, month: 3, day: 17, hour: 9, minute: 0))
        XCTAssertEqual(result.restoreAnchorDate, date(year: 2026, month: 3, day: 16, hour: 9, minute: 0))
    }

    // MARK: - Test 4: Single repeat day (Monday only), skip-next

    func testSkipNextSingleDay() {
        // Alarm at 7:00am on Monday only
        // Reference = Sunday 2026-03-15 at 22:00
        // Next 6 occurrences: Mon 3/16, Mon 3/23, Mon 3/30, Mon 4/6, Mon 4/13, Mon 4/20
        // skip-next: skip Mon 3/16, bridges = Mon 3/23, 3/30, 4/6, 4/13, 4/20
        // Each 7 days apart

        let result = BridgeDateCalculator.bridgeDates(
            hour: 7,
            minute: 0,
            repeatDays: [.monday],
            overrideKind: .skipNext,
            modifiedTime: nil,
            referenceDate: referenceSunday10pm,
            calendar: calendar
        )

        XCTAssertEqual(result.bridgeDates.count, 5)

        let expectedBridges: [Date] = [
            date(year: 2026, month: 3, day: 23, hour: 7, minute: 0),
            date(year: 2026, month: 3, day: 30, hour: 7, minute: 0),
            date(year: 2026, month: 4, day:  6, hour: 7, minute: 0),
            date(year: 2026, month: 4, day: 13, hour: 7, minute: 0),
            date(year: 2026, month: 4, day: 20, hour: 7, minute: 0),
        ]
        XCTAssertEqual(result.bridgeDates, expectedBridges, "Single-day skip-next should produce 5 consecutive Mondays 7 days apart")

        // All bridges should be exactly 7 days apart
        for i in 1..<result.bridgeDates.count {
            let gap = result.bridgeDates[i].timeIntervalSince(result.bridgeDates[i - 1])
            XCTAssertEqual(gap, 7 * 24 * 3600, accuracy: 1.0, "Bridges should be 7 days apart")
        }

        let expectedAnchor = date(year: 2026, month: 3, day: 16, hour: 7, minute: 0)
        XCTAssertEqual(result.restoreAnchorDate, expectedAnchor)
    }

    // MARK: - Test 5: Every-day alarm, skip-next

    func testSkipNextEveryDay() {
        // Alarm at 7:00am every day (Sun-Sat)
        // Reference = Sunday 2026-03-15 at 22:00
        // Next 6 occurrences (starting Mon 3/16): Mon 3/16, Tue 3/17, Wed 3/18, Thu 3/19, Fri 3/20, Sat 3/21
        // skip-next: skip Mon 3/16, bridges = Tue 3/17, Wed 3/18, Thu 3/19, Fri 3/20, Sat 3/21

        let result = BridgeDateCalculator.bridgeDates(
            hour: 7,
            minute: 0,
            repeatDays: AlarmWeekday.allCases,
            overrideKind: .skipNext,
            modifiedTime: nil,
            referenceDate: referenceSunday10pm,
            calendar: calendar
        )

        XCTAssertEqual(result.bridgeDates.count, 5)

        let expectedBridges: [Date] = [
            date(year: 2026, month: 3, day: 17, hour: 7, minute: 0), // Tue
            date(year: 2026, month: 3, day: 18, hour: 7, minute: 0), // Wed
            date(year: 2026, month: 3, day: 19, hour: 7, minute: 0), // Thu
            date(year: 2026, month: 3, day: 20, hour: 7, minute: 0), // Fri
            date(year: 2026, month: 3, day: 21, hour: 7, minute: 0), // Sat
        ]
        XCTAssertEqual(result.bridgeDates, expectedBridges, "Every-day skip-next should produce 5 consecutive days")

        // All bridges should be exactly 1 day apart
        for i in 1..<result.bridgeDates.count {
            let gap = result.bridgeDates[i].timeIntervalSince(result.bridgeDates[i - 1])
            XCTAssertEqual(gap, 24 * 3600, accuracy: 1.0, "Bridges should be 1 day apart")
        }

        let expectedAnchor = date(year: 2026, month: 3, day: 16, hour: 7, minute: 0) // Mon
        XCTAssertEqual(result.restoreAnchorDate, expectedAnchor)
    }

    // MARK: - DST edge cases (D-1)

    func testModifyNextIntoDSTGapDoesNotCrashAndRollsForward() {
        // US spring-forward: Sunday 2026-03-08, 02:00 EST jumps to 03:00 EDT.
        // Modifying a Sunday alarm to 02:30 targets a wall-clock time that does
        // not exist on that day. Must not crash; must resolve at/after the gap.
        let referenceSaturdayNoon = date(year: 2026, month: 3, day: 7, hour: 12, minute: 0)

        let result = BridgeDateCalculator.bridgeDates(
            hour: 9,
            minute: 0,
            repeatDays: [.sunday],
            overrideKind: .modifyNext,
            modifiedTime: (hour: 2, minute: 30),
            referenceDate: referenceSaturdayNoon,
            calendar: calendar
        )

        XCTAssertEqual(result.bridgeDates.count, 5)

        let resolved = calendar.dateComponents([.day, .hour], from: result.bridgeDates[0])
        XCTAssertEqual(resolved.day, 8, "modified bridge stays on the DST-transition day")
        XCTAssertGreaterThanOrEqual(resolved.hour ?? 0, 3, "nonexistent 02:30 resolves at/after the gap")

        // Modified time is before the canonical 9am slot, so the anchor is canonical.
        XCTAssertEqual(
            result.restoreAnchorDate,
            date(year: 2026, month: 3, day: 8, hour: 9, minute: 0)
        )
    }

    func testModifyNextIntoDSTFallBackAmbiguousHourResolves() {
        // US fall-back: Sunday 2026-11-01, 02:00 EDT falls back to 01:00 EST —
        // 01:30 exists twice. Calendar resolves to the first occurrence.
        let referenceSaturdayNoon = date(year: 2026, month: 10, day: 31, hour: 12, minute: 0)

        let result = BridgeDateCalculator.bridgeDates(
            hour: 9,
            minute: 0,
            repeatDays: [.sunday],
            overrideKind: .modifyNext,
            modifiedTime: (hour: 1, minute: 30),
            referenceDate: referenceSaturdayNoon,
            calendar: calendar
        )

        let resolved = calendar.dateComponents([.day, .hour, .minute], from: result.bridgeDates[0])
        XCTAssertEqual(resolved.day, 1)
        XCTAssertEqual(resolved.hour, 1)
        XCTAssertEqual(resolved.minute, 30)
    }

    // MARK: - Window invariants

    func testBridgeWindowIsAlwaysFiveAscending() {
        for kind in [OverrideKind.skipNext, .modifyNext] {
            let result = BridgeDateCalculator.bridgeDates(
                hour: 7,
                minute: 0,
                repeatDays: [.monday],
                overrideKind: kind,
                modifiedTime: kind == .modifyNext ? (hour: 8, minute: 0) : nil,
                referenceDate: referenceSunday10pm,
                calendar: calendar
            )
            XCTAssertEqual(result.bridgeDates.count, 5, "\(kind)")
            for i in 1..<result.bridgeDates.count {
                XCTAssertLessThan(result.bridgeDates[i - 1], result.bridgeDates[i], "\(kind) dates must ascend")
            }
        }
    }

    func testReferenceExactlyAtOccurrenceSkipsIt() {
        // The search starts strictly after referenceDate (+1s), so an alarm firing
        // at this exact instant is not its own "next occurrence".
        let mondaySevenAM = date(year: 2026, month: 3, day: 16, hour: 7, minute: 0)

        let result = BridgeDateCalculator.bridgeDates(
            hour: 7,
            minute: 0,
            repeatDays: [.monday],
            overrideKind: .skipNext,
            modifiedTime: nil,
            referenceDate: mondaySevenAM,
            calendar: calendar
        )

        // First occurrence (the skipped one / anchor) is NEXT Monday, not today.
        XCTAssertEqual(
            result.restoreAnchorDate,
            date(year: 2026, month: 3, day: 23, hour: 7, minute: 0)
        )
        XCTAssertEqual(
            result.bridgeDates[0],
            date(year: 2026, month: 3, day: 30, hour: 7, minute: 0)
        )
    }
}
