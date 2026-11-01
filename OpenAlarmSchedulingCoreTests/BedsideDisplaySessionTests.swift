import XCTest
@testable import OpenAlarmSchedulingCore

@MainActor
final class BedsideDisplaySessionTests: XCTestCase {
    func testClosingOrBackgroundingRestoresPreviousSetting() async {
        var idleTimerDisabled = false
        let session = BedsideDisplaySession(readIdleTimer: { idleTimerDisabled }, writeIdleTimer: { idleTimerDisabled = $0 })
        session.setActive(true)
        XCTAssertTrue(idleTimerDisabled)
        session.setActive(true)
        session.setActive(false)
        XCTAssertFalse(idleTimerDisabled)
        session.setActive(false)
        XCTAssertFalse(idleTimerDisabled)
        session.setActive(true)
        XCTAssertTrue(idleTimerDisabled)
        session.setActive(false)
        XCTAssertFalse(idleTimerDisabled)
    }

    func testAnExistingKeepAwakeRequestIsPreserved() async {
        var idleTimerDisabled = true
        let session = BedsideDisplaySession(readIdleTimer: { idleTimerDisabled }, writeIdleTimer: { idleTimerDisabled = $0 })
        session.setActive(true)
        session.setActive(false)
        XCTAssertTrue(idleTimerDisabled)
    }
}
