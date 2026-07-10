import Foundation

struct MathProblem: Equatable {
    enum Operation: String, CaseIterable, Hashable {
        case addition = "+"
        case subtraction = "\u{2212}"
        case multiplication = "\u{00d7}"
    }

    let left: Int
    let right: Int
    let operation: Operation

    var answer: Int {
        switch operation {
        case .addition:
            left + right
        case .subtraction:
            left - right
        case .multiplication:
            left * right
        }
    }

    var displayString: String {
        "\(left) \(operation.rawValue) \(right) = ?"
    }
}

enum MathProblemGenerator {
    static func generate(difficulty: MathDifficulty) -> MathProblem {
        var rng = SystemRandomNumberGenerator()
        return generate(difficulty: difficulty, using: &rng)
    }

    static func generate(difficulty: MathDifficulty, using rng: inout some RandomNumberGenerator) -> MathProblem {
        let operation = permittedOperations(for: difficulty).randomElement(using: &rng)!

        switch (difficulty, operation) {
        case (.easy, .addition):
            return problem(left: 2...9, right: 2...9, operation: operation, using: &rng)
        case (.medium, .addition):
            return problem(left: 10...50, right: 10...50, operation: operation, using: &rng)
        case (.medium, .multiplication):
            return problem(left: 2...9, right: 2...9, operation: operation, using: &rng)
        case (.hard, .addition):
            return problem(left: 50...200, right: 50...200, operation: operation, using: &rng)
        case (.hard, .multiplication):
            return problem(left: 10...20, right: 10...20, operation: operation, using: &rng)
        case (.extreme, .addition), (.nightmare, .addition):
            return problem(left: 100...999, right: 100...999, operation: operation, using: &rng)
        case (.extreme, .subtraction), (.nightmare, .subtraction):
            let first = Int.random(in: 100...999, using: &rng)
            let second = Int.random(in: 100...999, using: &rng)
            return MathProblem(left: max(first, second), right: min(first, second), operation: operation)
        case (.extreme, .multiplication):
            return problem(left: 10...99, right: 2...9, operation: operation, using: &rng)
        case (.nightmare, .multiplication):
            return problem(left: 25...99, right: 11...29, operation: operation, using: &rng)
        default:
            preconditionFailure("Unexpected math difficulty and operation")
        }
    }

    private static func permittedOperations(for difficulty: MathDifficulty) -> [MathProblem.Operation] {
        switch difficulty {
        case .easy:
            [.addition]
        case .medium, .hard:
            [.addition, .multiplication]
        case .extreme, .nightmare:
            [.addition, .subtraction, .multiplication]
        }
    }

    private static func problem(
        left: ClosedRange<Int>,
        right: ClosedRange<Int>,
        operation: MathProblem.Operation,
        using rng: inout some RandomNumberGenerator
    ) -> MathProblem {
        MathProblem(
            left: Int.random(in: left, using: &rng),
            right: Int.random(in: right, using: &rng),
            operation: operation
        )
    }
}
