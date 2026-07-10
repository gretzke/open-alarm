import SwiftUI

struct MathTaskView: View {
    let difficulty: MathDifficulty
    let totalCount: Int
    let mode: TaskMode
    var onEvent: (TaskEvent) -> Void

    @State private var currentProblem: MathProblem
    @State private var solvedCount = 0
    @State private var userAnswer = ""
    @State private var showWrongAnswer = false
    @State private var roundAdvanceTask: Task<Void, Never>?
    @State private var isShowingRoundSuccess = false

    @ScaledMetric(relativeTo: .largeTitle) private var problemFontSize: CGFloat = 40
    @ScaledMetric(relativeTo: .largeTitle) private var answerFontSize: CGFloat = 32

    init(
        difficulty: MathDifficulty,
        totalCount: Int,
        mode: TaskMode,
        onEvent: @escaping (TaskEvent) -> Void
    ) {
        self.difficulty = difficulty
        self.totalCount = min(max(totalCount, 1), 10)
        self.mode = mode
        self.onEvent = onEvent
        self._currentProblem = State(initialValue: MathProblemGenerator.generate(difficulty: difficulty))
    }

    var body: some View {
        ZStack {
            taskContent

            if isShowingRoundSuccess {
                TaskRoundSuccessEffect()
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isShowingRoundSuccess)
        .onDisappear {
            roundAdvanceTask?.cancel()
        }
    }

    private var taskContent: some View {
        VStack(spacing: OASpacing.l) {
            Spacer()

            Text(currentProblem.displayString)
                .font(OADawnType.display(problemFontSize))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Text(userAnswer.isEmpty ? "?" : userAnswer)
                .accessibilityLabel(String(localized: "a11y_math_answer_field"))
                .font(OADawnType.display(answerFontSize))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(Color.white.opacity(0.24), in: RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous))

            if showWrongAnswer {
                Text(String(localized: "task_math_wrong_answer"))
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }

            keypad

            HStack(spacing: OASpacing.s) {
                ForEach(0..<totalCount, id: \.self) { index in
                    Circle()
                        .fill(index < solvedCount ? Color.white : Color.white.opacity(0.35))
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityLabel(String(localized: "task_math_progress \(solvedCount) \(totalCount)"))

            Spacer()
        }
        .padding()
    }

    private var keypad: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: OASpacing.s), count: 3),
            spacing: OASpacing.s
        ) {
            ForEach(KeypadKey.allCases, id: \.self) { key in
                let isPrimary = key == .go
                Button {
                    handleKeyTap(key)
                } label: {
                    key.label
                        .font(OADawnType.button)
                        .foregroundStyle(isPrimary ? DawnPalette.inkDark : .white)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(
                            isPrimary ? Color.white : Color.white.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isShowingRoundSuccess)
                .accessibilityLabel(key.accessibilityLabel)
            }
        }
    }

    private func submitAnswer() {
        guard !isShowingRoundSuccess else { return }
        guard !userAnswer.isEmpty else { return }
        guard let answer = Int(userAnswer) else {
            regenerateAfterWrongAnswer()
            return
        }

        if answer == currentProblem.answer {
            solvedCount += 1
            onEvent(.progress(Double(solvedCount) / Double(totalCount)))
            if solvedCount >= totalCount {
                onEvent(.completed)
            } else {
                presentRoundSuccessThenContinue()
            }
        } else {
            regenerateAfterWrongAnswer()
        }
    }

    private func presentRoundSuccessThenContinue() {
        roundAdvanceTask?.cancel()
        Haptics.success()
        isShowingRoundSuccess = true

        roundAdvanceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: TaskRoundSuccessPresentation.duration)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            currentProblem = MathProblemGenerator.generate(difficulty: difficulty)
            userAnswer = ""
            showWrongAnswer = false
            isShowingRoundSuccess = false
            roundAdvanceTask = nil
        }
    }

    private func handleKeyTap(_ key: KeypadKey) {
        Haptics.impact(.light)

        switch key {
        case .digit(let digit):
            guard userAnswer.count < 6 else { return }
            userAnswer.append(digit)
        case .delete:
            guard !userAnswer.isEmpty else { return }
            userAnswer.removeLast()
        case .go:
            submitAnswer()
        }
    }

    private func regenerateAfterWrongAnswer() {
        Haptics.error()
        showWrongAnswer = true
        userAnswer = ""
        currentProblem = MathProblemGenerator.generate(difficulty: difficulty)
    }
}

private enum KeypadKey: Hashable, CaseIterable {
    case digit(String)
    case delete
    case go

    static let allCases: [KeypadKey] = [
        .digit("1"), .digit("2"), .digit("3"),
        .digit("4"), .digit("5"), .digit("6"),
        .digit("7"), .digit("8"), .digit("9"),
        .delete, .digit("0"), .go
    ]

    @ViewBuilder
    var label: some View {
        switch self {
        case .digit(let digit):
            Text(digit)
        case .delete:
            Image(systemName: "delete.left.fill")
        case .go:
            Text(L10n.taskMathKeypadGo)
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .digit(let digit):
            digit
        case .delete:
            L10n.a11yMathKeypadDelete
        case .go:
            L10n.taskMathKeypadGo
        }
    }
}
