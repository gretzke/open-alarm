import Foundation

struct MathProblem: Equatable {
    enum Operation: String, CaseIterable {
        case addition = "+"
        case multiplication = "\u{00d7}"
    }

    let left: Int
    let right: Int
    let operation: Operation
    var answer: Int {
        switch operation {
        case .addition: left + right
        case .multiplication: left * right
        }
    }

    var displayString: String {
        "\(left) \(operation.rawValue) \(right) = ?"
    }
}

enum MathProblemGenerator {
    static func generate(difficulty: MathDifficulty) -> MathProblem {
        let operation = MathProblem.Operation.allCases.randomElement()!
        switch (difficulty, operation) {
        case (.simple, .addition):
            return MathProblem(left: Int.random(in: 10...50), right: Int.random(in: 10...50), operation: .addition)
        case (.simple, .multiplication):
            return MathProblem(left: Int.random(in: 2...9), right: Int.random(in: 2...9), operation: .multiplication)
        case (.hard, .addition):
            return MathProblem(left: Int.random(in: 50...200), right: Int.random(in: 50...200), operation: .addition)
        case (.hard, .multiplication):
            return MathProblem(left: Int.random(in: 10...20), right: Int.random(in: 10...20), operation: .multiplication)
        }
    }
}
