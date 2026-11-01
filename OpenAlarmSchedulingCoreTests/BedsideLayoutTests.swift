import XCTest
@testable import OpenAlarmSchedulingCore

final class BedsideLayoutTests: XCTestCase {
    func testFlatDisplayRetainsFullViewport() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(FoldContentRegion.frame(in: bounds, divisions: [], occlusions: []), bounds)
        XCTAssertEqual(FoldContentRegion.frame(in: bounds, divisions: [CGRect(x: 400, y: 0, width: 0, height: 600)], occlusions: []), bounds)
    }

    func testTabletopUsesUpperPaneEvenWhenLowerPaneIsLarger() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let fold = CGRect(x: 0, y: 300, width: 600, height: 20)
        let frame = FoldContentRegion.frame(in: bounds, divisions: [fold], occlusions: [])
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 600, height: 300))
    }

    func testBookUsesLargestPaneOnEitherSideOfAsymmetricFold() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        for x in [300.0, 480.0] {
            let fold = CGRect(x: x, y: 0, width: 20, height: 600)
            let frame = FoldContentRegion.frame(in: bounds, divisions: [fold], occlusions: [])
            XCTAssertEqual(frame.width, 480)
            XCTAssertEqual(frame.height, 600)
            XCTAssertTrue(frame.intersection(fold).isEmpty)
        }
    }

    func testCameraAndFoldAreBothExcluded() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let fold = CGRect(x: 0, y: 390, width: 600, height: 20)
        let camera = CGRect(x: 270, y: 0, width: 60, height: 30)
        let frame = FoldContentRegion.frame(in: bounds, divisions: [fold], occlusions: [camera])
        XCTAssertEqual(frame, CGRect(x: 0, y: 30, width: 600, height: 360))
        XCTAssertTrue(frame.intersection(camera).isEmpty)
        XCTAssertTrue(frame.intersection(fold).isEmpty)
    }

    func testOffscreenAndEmptyRegionsDoNotConsumeSpace() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertEqual(FoldContentRegion.frame(in: bounds, divisions: [.zero], occlusions: [CGRect(x: -100, y: 0, width: 10, height: 100)]), bounds)
    }

    func testDawnUsesFinalFiveMinutesAndClampsAtExpiry() {
        XCTAssertEqual(progress(remaining: 1200, duration: 1500), 0)
        XCTAssertEqual(progress(remaining: 300, duration: 1500), 0)
        XCTAssertEqual(progress(remaining: 150, duration: 1500), 0.5)
        XCTAssertEqual(progress(remaining: 0, duration: 1500), 1)
        XCTAssertEqual(progress(remaining: -20, duration: 1500), 1)
    }

    func testShortNapUsesItsDurationAndExtensionCanReturnToDarkness() {
        XCTAssertEqual(progress(remaining: 60, duration: 120), 0.5)
        XCTAssertEqual(progress(remaining: 120, duration: 120), 0)
        XCTAssertEqual(progress(remaining: 420, duration: 120), 0)
    }

    func testPauseSnoozeAndInvalidDurationStayDark() {
        XCTAssertEqual(progress(remaining: 20, duration: 120, paused: true), 0)
        XCTAssertEqual(progress(remaining: 20, duration: 120, snoozing: true), 0)
        XCTAssertEqual(progress(remaining: 0, duration: 0), 0)
        XCTAssertEqual(progress(remaining: .infinity, duration: 120), 0)
    }

    private func progress(remaining: Double, duration: Double, paused: Bool = false, snoozing: Bool = false) -> Double {
        NapDawnProgress.value(remainingSeconds: remaining, durationSeconds: duration, isPaused: paused, isSnoozing: snoozing)
    }
}
