import SwiftUI

@MainActor
struct MemoryTaskView: View {
    let difficulty: Int
    let rounds: Int
    let mode: TaskMode
    var onEvent: (TaskEvent) -> Void

    @State private var pattern: Set<Int>
    @State private var roundsDone = 0
    @State private var flashedCells: Set<Int> = []
    @State private var foundCells: Set<Int> = []
    @State private var isPlaying = true
    @State private var didComplete = false
    @State private var playbackTask: Task<Void, Never>?
    @State private var roundAdvanceTask: Task<Void, Never>?
    @State private var isShowingRoundSuccess = false
    @State private var shakeGeneration = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let spec: MemoryPatternGenerator.Spec

    init(difficulty: Int, rounds: Int, mode: TaskMode, onEvent: @escaping (TaskEvent) -> Void) {
        let clampedDifficulty = min(max(difficulty, 1), 5)
        let clampedRounds = min(max(rounds, 1), 5)
        let spec = MemoryPatternGenerator.spec(difficulty: clampedDifficulty)

        self.difficulty = clampedDifficulty
        self.rounds = clampedRounds
        self.mode = mode
        self.onEvent = onEvent
        self.spec = spec
        _pattern = State(initialValue: Self.generatePatternSet(spec: spec))
    }

    var body: some View {
        VStack(spacing: OASpacing.xl) {
            Spacer(minLength: 0)

            Text(L10n.taskMemoryInstruction)
                .font(OADawnType.chip)
                .foregroundStyle(.white)

            grid
                .frame(maxWidth: 420)

            HStack(spacing: OASpacing.s) {
                ForEach(0..<rounds, id: \.self) { index in
                    Circle()
                        .fill(index < roundsDone ? Color.white : Color.white.opacity(0.35))
                        .frame(width: OASpacing.s, height: OASpacing.s)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(OASpacing.screenMargin)
        .onAppear(perform: startPlayback)
        .onDisappear {
            roundAdvanceTask?.cancel()
            stopPlayback()
        }
    }

    private var grid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(minimum: OASize.minTouchTarget), spacing: OASpacing.s),
            count: spec.gridSize
        )

        return ZStack {
            Group {
                if reduceMotion {
                    gridCells(columns: columns)
                } else {
                    gridCells(columns: columns)
                        .keyframeAnimator(initialValue: GridShakeValues(), trigger: shakeGeneration) { content, value in
                            content.offset(x: value.offset)
                        } keyframes: { _ in
                            KeyframeTrack(\.offset) {
                                LinearKeyframe(-10, duration: 0.06)
                                LinearKeyframe(10, duration: 0.06)
                                LinearKeyframe(-6, duration: 0.06)
                                LinearKeyframe(0, duration: 0.06)
                            }
                        }
                }
            }

            if isShowingRoundSuccess {
                TaskRoundSuccessEffect()
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isShowingRoundSuccess)
    }

    private func gridCells(columns: [GridItem]) -> some View {
        LazyVGrid(columns: columns, spacing: OASpacing.s) {
            ForEach(0..<(spec.gridSize * spec.gridSize), id: \.self) { index in
                Button {
                    handleTap(index)
                } label: {
                    RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous)
                        .fill(isLit(index) ? Color.white : Color.white.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous)
                                .stroke(Color.white.opacity(0.32), lineWidth: 1)
                        )
                        .frame(maxWidth: .infinity, minHeight: OASize.minTouchTarget)
                        .aspectRatio(1, contentMode: .fit)
                }
                .buttonStyle(.plain)
                .disabled(isPlaying || didComplete)
            }
        }
    }

    private func isLit(_ index: Int) -> Bool {
        flashedCells.contains(index) || foundCells.contains(index)
    }

    private func handleTap(_ index: Int) {
        guard !isPlaying, !didComplete else {
            return
        }

        guard !foundCells.contains(index) else {
            return
        }

        guard pattern.contains(index) else {
            Haptics.error()
            if !reduceMotion {
                shakeGeneration &+= 1
            }
            regeneratePatternAndPlay()
            return
        }

        Haptics.impact(.light)
        foundCells.insert(index)

        guard foundCells == pattern else {
            return
        }

        roundsDone += 1
        onEvent(.progress(Double(roundsDone) / Double(rounds)))

        // >= not ==: the preview keeps this view alive when the rounds stepper
        // changes, so roundsDone may already exceed a lowered goal.
        if roundsDone >= rounds {
            didComplete = true
            stopPlayback()
            onEvent(.completed)
        } else {
            presentRoundSuccessThenContinue()
        }
    }

    private func presentRoundSuccessThenContinue() {
        roundAdvanceTask?.cancel()
        isPlaying = true
        Haptics.success()
        isShowingRoundSuccess = true

        roundAdvanceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: TaskRoundSuccessPresentation.duration)
            } catch {
                return
            }

            guard !Task.isCancelled, !didComplete else {
                return
            }

            isShowingRoundSuccess = false
            roundAdvanceTask = nil
            regeneratePatternAndPlay()
        }
    }

    private func regeneratePatternAndPlay() {
        pattern = Self.generatePatternSet(spec: spec, excluding: pattern)
        foundCells.removeAll()
        startPlayback()
    }

    private func startPlayback() {
        playbackTask?.cancel()
        guard !didComplete else {
            return
        }

        isPlaying = true
        flashedCells = []
        let flashedSet = pattern
        let flashSeconds = spec.flashSeconds

        playbackTask = Task { @MainActor in
            guard !Task.isCancelled, !didComplete else {
                return
            }

            flashedCells = flashedSet
            Haptics.selection()

            do {
                try await Task.sleep(for: .seconds(flashSeconds))
            } catch {
                return
            }

            guard !Task.isCancelled, !didComplete else {
                return
            }
            flashedCells = []
            isPlaying = false
            playbackTask = nil
        }
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        flashedCells = []
        isPlaying = true
    }

    private static func generatePatternSet(
        spec: MemoryPatternGenerator.Spec,
        excluding previous: Set<Int> = []
    ) -> Set<Int> {
        var rng = SystemRandomNumberGenerator()
        return MemoryPatternGenerator.patternSet(spec: spec, excluding: previous, using: &rng)
    }
}

private struct GridShakeValues {
    var offset: CGFloat = 0
}
