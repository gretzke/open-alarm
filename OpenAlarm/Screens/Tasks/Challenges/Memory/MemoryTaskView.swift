import SwiftUI

@MainActor
struct MemoryTaskView: View {
    let difficulty: Int
    let rounds: Int
    let mode: TaskMode
    var onEvent: (TaskEvent) -> Void

    @State private var pattern: [Int]
    @State private var inputIndex = 0
    @State private var roundsDone = 0
    @State private var litCell: Int?
    @State private var correctCells: Set<Int> = []
    @State private var isPlaying = true
    @State private var didComplete = false
    @State private var playbackTask: Task<Void, Never>?
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
        _pattern = State(initialValue: Self.generatePattern(spec: spec))
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
        .onDisappear(perform: stopPlayback)
    }

    private var grid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(minimum: OASize.minTouchTarget), spacing: OASpacing.s),
            count: spec.gridSize
        )

        return Group {
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
        litCell == index || correctCells.contains(index)
    }

    private func handleTap(_ index: Int) {
        guard !isPlaying, !didComplete else {
            return
        }

        guard index == pattern[inputIndex] else {
            Haptics.error()
            if !reduceMotion {
                shakeGeneration &+= 1
            }
            regeneratePatternAndPlay()
            return
        }

        Haptics.impact(.light)
        correctCells.insert(index)
        inputIndex += 1

        guard inputIndex == pattern.count else {
            return
        }

        roundsDone += 1
        onEvent(.progress(Double(roundsDone) / Double(rounds)))

        if roundsDone == rounds {
            didComplete = true
            stopPlayback()
            onEvent(.completed)
        } else {
            regeneratePatternAndPlay()
        }
    }

    private func regeneratePatternAndPlay() {
        var nextPattern = Self.generatePattern(spec: spec)
        while nextPattern == pattern {
            nextPattern = Self.generatePattern(spec: spec)
        }
        pattern = nextPattern
        inputIndex = 0
        correctCells.removeAll()
        startPlayback()
    }

    private func startPlayback() {
        playbackTask?.cancel()
        guard !didComplete else {
            return
        }

        isPlaying = true
        litCell = nil
        let sequence = pattern
        let flashSeconds = spec.flashSeconds

        playbackTask = Task { @MainActor in
            for cell in sequence {
                guard !Task.isCancelled, !didComplete else {
                    return
                }

                litCell = cell
                Haptics.selection()

                do {
                    try await Task.sleep(for: .seconds(flashSeconds))
                } catch {
                    return
                }

                guard !Task.isCancelled, !didComplete else {
                    return
                }
                litCell = nil
            }

            guard !Task.isCancelled, !didComplete else {
                return
            }
            isPlaying = false
            playbackTask = nil
        }
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        litCell = nil
        isPlaying = true
    }

    private static func generatePattern(spec: MemoryPatternGenerator.Spec) -> [Int] {
        var rng = SystemRandomNumberGenerator()
        return MemoryPatternGenerator.pattern(spec: spec, using: &rng)
    }
}

private struct GridShakeValues {
    var offset: CGFloat = 0
}
