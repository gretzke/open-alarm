import XCTest
@testable import OpenAlarmSchedulingCore

final class MathGeneratorTests: XCTestCase {
    func testGeneratedProblemsRespectDifficultyRules() {
        for difficulty in MathDifficulty.allCases {
            var rng = SplitMix64(seed: UInt64(difficulty.allCasesIndex + 1))

            for _ in 0..<200 {
                let problem = MathProblemGenerator.generate(difficulty: difficulty, using: &rng)
                assertProblem(problem, matches: difficulty)
                XCTAssertEqual(problem.answer, arithmeticAnswer(for: problem))

                if case .subtraction = problem.operation {
                    XCTAssertGreaterThanOrEqual(problem.answer, 0)
                }
            }
        }
    }

    func testSeededGeneratorProducesEveryPermittedOperation() {
        for difficulty in MathDifficulty.allCases {
            var rng = SplitMix64(seed: UInt64(100 + difficulty.allCasesIndex))
            var generatedOperations = Set<MathProblem.Operation>()

            for _ in 0..<200 {
                generatedOperations.insert(MathProblemGenerator.generate(difficulty: difficulty, using: &rng).operation)
            }

            XCTAssertEqual(generatedOperations, permittedOperations(for: difficulty))
        }
    }

    func testMathTaskCodableRoundTripsAllDifficulties() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for difficulty in MathDifficulty.allCases {
            let task = AlarmTask.math(difficulty: difficulty, count: 3)
            XCTAssertEqual(try decoder.decode(AlarmTask.self, from: encoder.encode(task)), task)
        }
    }

    private func assertProblem(_ problem: MathProblem, matches difficulty: MathDifficulty, file: StaticString = #filePath, line: UInt = #line) {
        switch (difficulty, problem.operation) {
        case (.easy, .addition):
            XCTAssertTrue((2...9).contains(problem.left), file: file, line: line)
            XCTAssertTrue((2...9).contains(problem.right), file: file, line: line)
        case (.medium, .addition):
            XCTAssertTrue((10...50).contains(problem.left), file: file, line: line)
            XCTAssertTrue((10...50).contains(problem.right), file: file, line: line)
        case (.medium, .multiplication):
            XCTAssertTrue((2...9).contains(problem.left), file: file, line: line)
            XCTAssertTrue((2...9).contains(problem.right), file: file, line: line)
        case (.hard, .addition):
            XCTAssertTrue((50...200).contains(problem.left), file: file, line: line)
            XCTAssertTrue((50...200).contains(problem.right), file: file, line: line)
        case (.hard, .multiplication):
            XCTAssertTrue((10...20).contains(problem.left), file: file, line: line)
            XCTAssertTrue((10...20).contains(problem.right), file: file, line: line)
        case (.extreme, .addition), (.nightmare, .addition), (.extreme, .subtraction), (.nightmare, .subtraction):
            XCTAssertTrue((100...999).contains(problem.left), file: file, line: line)
            XCTAssertTrue((100...999).contains(problem.right), file: file, line: line)
            if case .subtraction = problem.operation {
                XCTAssertGreaterThanOrEqual(problem.left, problem.right, file: file, line: line)
            }
        case (.extreme, .multiplication):
            XCTAssertTrue((10...99).contains(problem.left), file: file, line: line)
            XCTAssertTrue((2...9).contains(problem.right), file: file, line: line)
        case (.nightmare, .multiplication):
            XCTAssertTrue((25...99).contains(problem.left), file: file, line: line)
            XCTAssertTrue((11...29).contains(problem.right), file: file, line: line)
        default:
            XCTFail("Unexpected \(problem.operation) problem for \(difficulty)", file: file, line: line)
        }
    }

    private func permittedOperations(for difficulty: MathDifficulty) -> Set<MathProblem.Operation> {
        switch difficulty {
        case .easy:
            [.addition]
        case .medium, .hard:
            [.addition, .multiplication]
        case .extreme, .nightmare:
            [.addition, .subtraction, .multiplication]
        }
    }

    private func arithmeticAnswer(for problem: MathProblem) -> Int {
        switch problem.operation {
        case .addition:
            problem.left + problem.right
        case .subtraction:
            problem.left - problem.right
        case .multiplication:
            problem.left * problem.right
        }
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

private extension MathDifficulty {
    var allCasesIndex: Int {
        MathDifficulty.allCases.firstIndex(of: self)!
    }
}
