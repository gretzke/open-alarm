import Foundation

/// Rhythm-gated step detector for user-acceleration magnitudes measured in g.
///
/// A crest is only credited after it joins a walking cadence, so isolated alarm
/// sound or haptic impulses cannot advance a wake-up task.
struct StepDetector {
    private(set) var stepCount = 0

    // Field-tuning constants. The EMA attenuates speaker/haptic buzz, and the
    // cadence window admits normal walking while rejecting short repeated buzz.
    private static let lowPassAlpha = 0.25
    private static let upperThreshold = 0.12
    private static let lowerThreshold = 0.06
    private static let minInterval = 0.30
    private static let maxInterval = 1.50
    private static let warmupSteps = 3

    private var smoothedMagnitude = 0.0
    private var isArmed = true
    private var elapsedTime = 0.0
    private var previousCandidateTime: Double?
    private var rhythmicCandidates = 0

    /// Processes a single acceleration sample, returning the steps newly
    /// credited by it (zero, one, or the retroactive warm-up credit).
    mutating func process(magnitude: Double, dt: Double) -> Int {
        elapsedTime += max(dt, 0)
        smoothedMagnitude += Self.lowPassAlpha * (max(magnitude, 0) - smoothedMagnitude)

        if smoothedMagnitude <= Self.lowerThreshold {
            isArmed = true
        }

        guard isArmed, smoothedMagnitude >= Self.upperThreshold else {
            return 0
        }

        isArmed = false
        let candidateTime = elapsedTime
        defer { previousCandidateTime = candidateTime }

        guard let previousCandidateTime else {
            rhythmicCandidates = 1
            return 0
        }

        let interval = candidateTime - previousCandidateTime
        guard (Self.minInterval...Self.maxInterval).contains(interval) else {
            rhythmicCandidates = 1
            return 0
        }

        rhythmicCandidates += 1
        if rhythmicCandidates == Self.warmupSteps {
            stepCount += Self.warmupSteps
            return Self.warmupSteps
        }

        guard rhythmicCandidates > Self.warmupSteps else {
            return 0
        }

        stepCount += 1
        return 1
    }

    mutating func reset() {
        stepCount = 0
        smoothedMagnitude = 0
        isArmed = true
        elapsedTime = 0
        previousCandidateTime = nil
        rhythmicCandidates = 0
    }
}
