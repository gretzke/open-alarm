import SwiftUI

struct MathTaskView: View {
    let difficulty: MathDifficulty
    let totalCount: Int
    var onCompleted: () -> Void

    @State private var currentProblem: MathProblem
    @State private var solvedCount = 0
    @State private var userAnswer = ""
    @State private var showWrongAnswer = false

    @ScaledMetric(relativeTo: .largeTitle) private var problemFontSize: CGFloat = 40
    @ScaledMetric(relativeTo: .largeTitle) private var answerFontSize: CGFloat = 32

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
                .font(OAType.display(problemFontSize))
                .foregroundStyle(OAColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            TextField(text: $userAnswer) {
                EmptyView()
            }
                .accessibilityLabel(String(localized: "a11y_math_answer_field"))
                .keyboardType(.numberPad)
                .font(.system(size: answerFontSize, weight: .medium, design: .rounded))
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
                    .font(OAType.buttonLabel)
                    .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
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
