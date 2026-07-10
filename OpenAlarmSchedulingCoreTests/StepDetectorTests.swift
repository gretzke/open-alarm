import XCTest
@testable import OpenAlarmSchedulingCore

final class StepDetectorTests: XCTestCase {
    func testHandheldWalkingSignalCountsSteps() {
        // Realistic hand-held walking: brief ~0.15 g heel-strike transients at
        // 2 Hz over a ~0.03 g noise floor. Calibration reference: the shake
        // task requires 0.8+ g on the same signal, so walking is far weaker.
        var detector = StepDetector()
        let sampleRate = 50.0
        let duration = 10.0
        let transient = [0.12, 0.18, 0.14, 0.08]

        for sample in 0..<Int(duration * sampleRate) {
            let phase = sample % Int(sampleRate / 2)
            let floorNoise = 0.02 + Double((sample * 37) % 7) / 350
            let magnitude = phase < transient.count ? transient[phase] + floorNoise : floorNoise
            _ = detector.process(magnitude: magnitude, dt: 1 / sampleRate)
        }

        XCTAssertTrue((16...22).contains(detector.stepCount), "counted \(detector.stepCount) steps")
    }

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

    func testSecondRhythmicCrestRetroactivelyCreditsWarmup() {
        var detector = StepDetector()

        feedCrest(into: &detector)
        feedStillness(into: &detector, samples: 20)
        XCTAssertEqual(detector.stepCount, 0)

        feedCrest(into: &detector)
        XCTAssertEqual(detector.stepCount, 2)
    }

    func testContinuousVibrationPlateauDoesNotCountSteps() {
        // A phone lying on a table with the alarm blaring: the speaker raises
        // the magnitude to a sustained plateau. The slow baseline absorbs it,
        // so only the initial rise can produce a single (uncounted) candidate.
        var detector = StepDetector()
        feedStillness(into: &detector, samples: 50)

        for _ in 0..<500 {
            _ = detector.process(magnitude: 0.3, dt: 0.02)
        }

        XCTAssertEqual(detector.stepCount, 0)
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
