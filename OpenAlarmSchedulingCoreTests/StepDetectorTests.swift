import XCTest
@testable import OpenAlarmSchedulingCore

final class StepDetectorTests: XCTestCase {
    func testGaitSignalCreditsRhythmicCrests() {
        var detector = StepDetector()
        var credited = 0
        let sampleRate = 50.0
        let duration = 10.0

        for sample in 0..<Int(duration * sampleRate) {
            // A walking-like impact pulse every 0.5 seconds leaves enough low
            // samples for hysteresis to re-arm between rhythmic crests.
            let magnitude = sample.isMultiple(of: Int(sampleRate / 2)) ? 0.5 : 0
            credited += detector.process(magnitude: magnitude, dt: 1 / sampleRate)
        }

        XCTAssertEqual(credited, detector.stepCount)
        XCTAssertTrue((18...22).contains(detector.stepCount), "credited \(detector.stepCount) steps")
    }

    func testStillnessNoiseDoesNotCountSteps() {
        var detector = StepDetector()

        for sample in 0..<500 {
            let noise = 0.02 + Double((sample * 37) % 7) / 10_000
            _ = detector.process(magnitude: noise, dt: 0.02)
        }

        XCTAssertEqual(detector.stepCount, 0)
    }

    func testIsolatedSpikeDoesNotCountStep() {
        var detector = StepDetector()
        feedStillness(into: &detector, samples: 25)
        _ = detector.process(magnitude: 0.5, dt: 0.02)
        feedStillness(into: &detector, samples: 100)

        XCTAssertEqual(detector.stepCount, 0)
    }

    func testSpikesSeparatedBeyondCadenceDoNotCountSteps() {
        var detector = StepDetector()
        feedCrest(into: &detector)
        feedStillness(into: &detector, samples: 150)
        feedCrest(into: &detector)

        XCTAssertEqual(detector.stepCount, 0)
    }

    func testHighFrequencyBuzzDoesNotCountSteps() {
        var detector = StepDetector()

        for _ in 0..<40 {
            feedCrest(into: &detector)
            feedStillness(into: &detector, samples: 5)
        }

        XCTAssertEqual(detector.stepCount, 0)
    }

    func testThirdRhythmicCrestRetroactivelyCreditsWarmup() {
        var detector = StepDetector()

        feedCrest(into: &detector)
        feedStillness(into: &detector, samples: 20)
        XCTAssertEqual(detector.stepCount, 0)

        feedCrest(into: &detector)
        feedStillness(into: &detector, samples: 20)
        XCTAssertEqual(detector.stepCount, 0)

        feedCrest(into: &detector)
        XCTAssertEqual(detector.stepCount, 3)
    }

    func testResetClearsCountAndRhythmState() {
        var detector = StepDetector()
        for _ in 0..<3 {
            feedCrest(into: &detector)
            feedStillness(into: &detector, samples: 20)
        }
        XCTAssertEqual(detector.stepCount, 3)

        detector.reset()

        XCTAssertEqual(detector.stepCount, 0)
        feedCrest(into: &detector)
        XCTAssertEqual(detector.stepCount, 0)
    }

    private func feedCrest(into detector: inout StepDetector) {
        _ = detector.process(magnitude: 0.5, dt: 0.02)
    }

    private func feedStillness(into detector: inout StepDetector, samples: Int) {
        for _ in 0..<samples {
            _ = detector.process(magnitude: 0.0, dt: 0.02)
        }
    }
}
