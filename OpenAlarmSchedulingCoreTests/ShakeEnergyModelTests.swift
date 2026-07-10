import XCTest
@testable import OpenAlarmSchedulingCore

final class ShakeEnergyModelTests: XCTestCase {
    func testIntensityIsClampedToOneThroughFive() {
        XCTAssertEqual(ShakeEnergyModel(intensity: 0).intensity, 1)
        XCTAssertEqual(ShakeEnergyModel(intensity: 6).intensity, 5)
    }

    func testRestProducesZeroProgress() {
        var model = ShakeEnergyModel(intensity: 3)

        for _ in 0..<500 {
            model.ingest(magnitude: 0.3, dt: 0.02)
        }

        XCTAssertEqual(model.progress, 0, accuracy: 0.000_001)
        XCTAssertFalse(model.isComplete)
    }

    func testCompletionOccursAtExpectedExcessEnergySample() {
        let intensity = 3
        var model = ShakeEnergyModel(intensity: intensity)
        let magnitude = 2.0
        let dt = 0.02
        let threshold = 0.8 + 0.3 * Double(intensity - 1)
        let goal = 1.2 + 0.9 * Double(intensity - 1)
        let expectedTime = goal / (magnitude - threshold)
        let observedSteps = Int(ceil(expectedTime / dt))

        var completionSample: Int?
        for sample in 1...(observedSteps + 1) {
            model.ingest(magnitude: magnitude, dt: dt)
            if model.isComplete {
                completionSample = sample
                break
            }
        }

        XCTAssertNotNil(completionSample)
        XCTAssertEqual(completionSample!, observedSteps, accuracy: 1)
    }

    func testProgressDecaysAtRestButNeverBelowZero() {
        var model = ShakeEnergyModel(intensity: 1)
        model.ingest(magnitude: 2.0, dt: 0.1)
        let chargedProgress = model.progress

        model.ingest(magnitude: 0.3, dt: 1)
        XCTAssertLessThan(model.progress, chargedProgress)

        for _ in 0..<100 {
            model.ingest(magnitude: 0.3, dt: 1)
        }
        XCTAssertEqual(model.progress, 0, accuracy: 0.000_001)
    }

    func testCompletionLatchesAfterLaterDecay() {
        var model = ShakeEnergyModel(intensity: 1)
        while !model.isComplete {
            model.ingest(magnitude: 2.0, dt: 0.02)
        }

        for _ in 0..<100 {
            model.ingest(magnitude: 0.3, dt: 1)
        }

        XCTAssertTrue(model.isComplete)
        XCTAssertEqual(model.progress, 0, accuracy: 0.000_001)
    }

    func testShakeTaskCodableRoundTripAndClampsIntensity() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let normalTask: AlarmTask = .shake(intensity: 3)
        let outOfRangeTask: AlarmTask = .shake(intensity: 99)

        XCTAssertEqual(
            try decoder.decode(AlarmTask.self, from: encoder.encode(normalTask)),
            .shake(intensity: 3)
        )
        XCTAssertEqual(
            try decoder.decode(AlarmTask.self, from: encoder.encode(outOfRangeTask)),
            .shake(intensity: 5)
        )
    }
}
