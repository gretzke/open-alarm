import XCTest
@testable import OpenAlarmSchedulingCore

final class RingtonePlaybackOffsetTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    func testOffsetWrapsWithinExcerptDuration() {
        XCTAssertEqual(offset(after: 23, duration: 30), 23, accuracy: 0.001)
        XCTAssertEqual(offset(after: 45, duration: 30), 15, accuracy: 0.001)
        XCTAssertEqual(offset(after: 60, duration: 30), 0, accuracy: 0.001)
    }

    func testOffsetReturnsZeroForInvalidElapsedOrDuration() {
        XCTAssertEqual(offset(after: -1, duration: 30), 0)
        XCTAssertEqual(offset(after: 1, duration: 0), 0)
        XCTAssertEqual(offset(after: 25 * 60 * 60, duration: 30), 0)
    }

    private func offset(after elapsed: TimeInterval, duration: TimeInterval) -> TimeInterval {
        RingtonePlayback.offset(
            alertStartedAt: start,
            now: start.addingTimeInterval(elapsed),
            excerptDuration: duration
        )
    }
}
