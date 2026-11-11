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
        GeometryReader { geometry in
            // Scrolls only when even minimum-size keys cannot fit, which happens at
            // accessibility text sizes. At the default size the budget always fits.
            ScrollView {
                PuzzleArrangementLayout(
                    puzzle: .keypad(columns: 3, rows: 4, maxWidth: 360, maxKeyHeight: 64),
                    spacing: OASpacing.l,
                    cellSpacing: OASpacing.s,
                    minimumCell: mode.minimumPuzzleCell,
                    columnShare: 0.5,
                    shortfall: .overflow,
                    budget: CGSize(
                        width: max(0, geometry.size.width - Self.contentPadding * 2),
                        height: max(0, geometry.size.height - Self.contentPadding * 2)
                    )
                ) {
                    problemBlock
                    keypad
                    progressDots
                }
                .padding(Self.contentPadding)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private static let contentPadding: CGFloat = OASpacing.l

    private var problemBlock: some View {
        VStack(spacing: OASpacing.l) {
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
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(Color.white.opacity(0.24), in: RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous))

            // The line stays reserved, so the message never moves the keypad.
            Text(String(localized: "task_math_wrong_answer"))
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .opacity(showWrongAnswer ? 1 : 0)
                .accessibilityHidden(!showWrongAnswer)
        }
    }

    private var progressDots: some View {
        HStack(spacing: OASpacing.s) {
            ForEach(0..<totalCount, id: \.self) { index in
                Circle()
                    .fill(index < solvedCount ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityLabel(String(localized: "task_math_progress \(solvedCount) \(totalCount)"))
    }

    /// Equal rows of flexible keys, so the keys fill the size that
    /// PuzzleArrangementLayout proposes (44 to 64 pt high).
    private var keypad: some View {
        VStack(spacing: OASpacing.s) {
            ForEach(Array(stride(from: 0, to: KeypadKey.allCases.count, by: 3)), id: \.self) { rowStart in
                HStack(spacing: OASpacing.s) {
                    ForEach(KeypadKey.allCases[rowStart..<(rowStart + 3)], id: \.self) { key in
                        keyButton(key)
                    }
                }
            }
        }
    }

    private func keyButton(_ key: KeypadKey) -> some View {
        let isPrimary = key == .go
        return Button {
            handleKeyTap(key)
        } label: {
            key.label
                .font(OADawnType.button)
                // Keys are at least 44 pt high, so the label stops growing at AX1 and
                // scales down if a long localized label needs it.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(isPrimary ? DawnPalette.inkDark : .white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    isPrimary ? Color.white : Color.white.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(isShowingRoundSuccess)
        .accessibilityLabel(key.accessibilityLabel)
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
