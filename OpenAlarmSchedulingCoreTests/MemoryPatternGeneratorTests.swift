import XCTest
@testable import OpenAlarmSchedulingCore

final class MemoryPatternGeneratorTests: XCTestCase {
    func testSpecsMatchDifficultyTableAndClampInputs() {
        let expected: [MemoryPatternGenerator.Spec] = [
            .init(gridSize: 3, patternCount: 3, flashSeconds: 1.2),
            .init(gridSize: 3, patternCount: 4, flashSeconds: 1.1),
            .init(gridSize: 4, patternCount: 5, flashSeconds: 1.0),
            .init(gridSize: 4, patternCount: 7, flashSeconds: 0.9),
            .init(gridSize: 5, patternCount: 8, flashSeconds: 0.8)
        ]

        XCTAssertEqual(MemoryPatternGenerator.spec(difficulty: 0), expected[0])
        XCTAssertEqual(MemoryPatternGenerator.spec(difficulty: 6), expected[4])

        for difficulty in 1...5 {
            XCTAssertEqual(MemoryPatternGenerator.spec(difficulty: difficulty), expected[difficulty - 1])
        }
    }

    func testPatternSetsHaveExpectedCountDistinctnessAndBounds() {
        for difficulty in 1...5 {
            let spec = MemoryPatternGenerator.spec(difficulty: difficulty)

            for seed in 0..<500 {
                var rng = SplitMix64(seed: UInt64(seed))
                let pattern = MemoryPatternGenerator.patternSet(spec: spec, using: &rng)

                XCTAssertEqual(pattern.count, spec.patternCount)
                XCTAssertTrue(pattern.allSatisfy { (0..<(spec.gridSize * spec.gridSize)).contains($0) })
            }
        }
    }

    func testPatternSetGenerationIsDeterministicForSeededGenerator() {
        let spec = MemoryPatternGenerator.spec(difficulty: 5)
        var firstRNG = SplitMix64(seed: 0xF00D)
        var secondRNG = SplitMix64(seed: 0xF00D)

        XCTAssertEqual(
            MemoryPatternGenerator.patternSet(spec: spec, using: &firstRNG),
            MemoryPatternGenerator.patternSet(spec: spec, using: &secondRNG)
        )
    }

    func testPatternSetDiffersFromPreviousWhenAlternativeExists() {
        let spec = MemoryPatternGenerator.Spec(gridSize: 3, patternCount: 3, flashSeconds: 1)

        for seed in 0..<100 {
            var firstRNG = SplitMix64(seed: UInt64(seed))
            let previous = MemoryPatternGenerator.patternSet(spec: spec, using: &firstRNG)
            var secondRNG = SplitMix64(seed: UInt64(seed))

            XCTAssertNotEqual(
                MemoryPatternGenerator.patternSet(spec: spec, excluding: previous, using: &secondRNG),
                previous
            )
        }
    }

    func testPatternSetReturnsFullSetWhenNoAlternativeExists() {
        let spec = MemoryPatternGenerator.Spec(gridSize: 2, patternCount: 4, flashSeconds: 1)
        var rng = SplitMix64(seed: 42)

        XCTAssertEqual(
            MemoryPatternGenerator.patternSet(spec: spec, excluding: [0, 1, 2, 3], using: &rng),
            [0, 1, 2, 3]
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
