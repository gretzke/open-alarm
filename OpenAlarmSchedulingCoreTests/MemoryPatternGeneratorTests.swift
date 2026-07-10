import XCTest
@testable import OpenAlarmSchedulingCore

final class MemoryPatternGeneratorTests: XCTestCase {
    func testSpecsMatchDifficultyTableAndClampInputs() {
        let expected: [MemoryPatternGenerator.Spec] = [
            .init(gridSize: 3, patternLength: 3, flashSeconds: 0.60),
            .init(gridSize: 3, patternLength: 4, flashSeconds: 0.54),
            .init(gridSize: 4, patternLength: 5, flashSeconds: 0.47),
            .init(gridSize: 4, patternLength: 6, flashSeconds: 0.41),
            .init(gridSize: 5, patternLength: 7, flashSeconds: 0.35)
        ]

        XCTAssertEqual(MemoryPatternGenerator.spec(difficulty: 0), expected[0])
        XCTAssertEqual(MemoryPatternGenerator.spec(difficulty: 6), expected[4])

        for difficulty in 1...5 {
            XCTAssertEqual(MemoryPatternGenerator.spec(difficulty: difficulty), expected[difficulty - 1])
        }
    }

    func testPatternsHaveExpectedLengthBoundsAndNoImmediateRepeatsOverSeededRuns() {
        for difficulty in 1...5 {
            let spec = MemoryPatternGenerator.spec(difficulty: difficulty)

            for seed in 0..<500 {
                var rng = SplitMix64(seed: UInt64(seed))
                let pattern = MemoryPatternGenerator.pattern(spec: spec, using: &rng)

                XCTAssertEqual(pattern.count, spec.patternLength)
                XCTAssertTrue(pattern.allSatisfy { (0..<(spec.gridSize * spec.gridSize)).contains($0) })
                XCTAssertTrue(zip(pattern, pattern.dropFirst()).allSatisfy { $0 != $1 })
            }
        }
    }

    func testPatternGenerationIsDeterministicForSeededGenerator() {
        let spec = MemoryPatternGenerator.spec(difficulty: 5)
        var firstRNG = SplitMix64(seed: 0xF00D)
        var secondRNG = SplitMix64(seed: 0xF00D)

        XCTAssertEqual(
            MemoryPatternGenerator.pattern(spec: spec, using: &firstRNG),
            MemoryPatternGenerator.pattern(spec: spec, using: &secondRNG)
        )
    }

    func testMemoryTaskCodableRoundTripAndClampsParameters() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let normalTask: AlarmTask = .memory(difficulty: 3, rounds: 4)
        let outOfRangeTask: AlarmTask = .memory(difficulty: 0, rounds: 9)

        XCTAssertEqual(
            try decoder.decode(AlarmTask.self, from: encoder.encode(normalTask)),
            .memory(difficulty: 3, rounds: 4)
        )
        XCTAssertEqual(
            try decoder.decode(AlarmTask.self, from: encoder.encode(outOfRangeTask)),
            .memory(difficulty: 1, rounds: 5)
        )
    }
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
