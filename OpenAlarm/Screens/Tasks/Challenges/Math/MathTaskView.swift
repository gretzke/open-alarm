import SwiftUI

struct MathTaskView: View {
    let difficulty: MathDifficulty
    let totalCount: Int
    var onCompleted: () -> Void

    @State private var currentProblem: MathProblem
    @State private var solvedCount = 0
    @State private var userAnswer = ""
    @State private var showWrongAnswer = false

    init(difficulty: MathDifficulty, totalCount: Int, onCompleted: @escaping () -> Void) {
        self.difficulty = difficulty
        self.totalCount = totalCount
        self.onCompleted = onCompleted
        self._currentProblem = State(initialValue: MathProblemGenerator.generate(difficulty: difficulty))
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text(String(localized: "task_math_progress \(solvedCount + 1) \(totalCount)"))
                .font(.subheadline)
                .foregroundStyle(OAColor.textSecondary)

            Text(currentProblem.displayString)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(OAColor.textPrimary)

            TextField("", text: $userAnswer)
                .keyboardType(.numberPad)
                .font(.system(size: 32, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)
                .padding()
                .oaGlassPanel()

            if showWrongAnswer {
                Text(String(localized: "task_math_wrong_answer"))
                    .font(.subheadline)
                    .foregroundStyle(OAColor.danger)
            }

            Button {
                submitAnswer()
            } label: {
                Text(String(localized: "task_math_submit"))
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.glassProminent)
            .tint(OAColor.actionCyan)
            .disabled(userAnswer.isEmpty)

            Spacer()
        }
        .padding()
    }

    private func submitAnswer() {
        guard let answer = Int(userAnswer) else {
            showWrongAnswer = true
            return
        }

        if answer == currentProblem.answer {
            solvedCount += 1
            if solvedCount >= totalCount {
                onCompleted()
            } else {
                currentProblem = MathProblemGenerator.generate(difficulty: difficulty)
                userAnswer = ""
                showWrongAnswer = false
            }
        } else {
            showWrongAnswer = true
            userAnswer = ""
            currentProblem = MathProblemGenerator.generate(difficulty: difficulty)
        }
    }
}
