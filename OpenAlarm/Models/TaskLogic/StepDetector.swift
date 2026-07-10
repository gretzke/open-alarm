import Foundation

/// Rhythm-gated step detector for user-acceleration magnitudes measured in g.
///
/// The signal is split into a fast EMA (tracks heel-strike transients) and a
/// slow EMA (tracks whatever baseline the phone currently experiences — rest,
/// speaker vibration, a vehicle). A step candidate is a crest of the
/// fast-over-slow deviation, so light hand-held walking registers while
/// continuous buzz merely raises the baseline. Candidates only count once they
/// form a walking cadence, so isolated alarm haptics or picking the phone up
/// cannot advance a wake-up task.
///
/// Calibration reference: hand-held walking produces ~0.1–0.2 g transients on
/// a ~0.03 g floor; the shake task requires 0.8+ g on the same signal.
struct StepDetector {
    private(set) var stepCount = 0

    // Field-tuning constants.
    private static let fastAlpha = 0.4
    private static let slowAlpha = 0.02
    private static let riseThreshold = 0.035
    private static let fallThreshold = 0.015
    private static let minInterval = 0.25
    private static let maxInterval = 2.0
    private static let warmupSteps = 2

    private var fast = 0.0
    private var slow = 0.0
    private var isArmed = true
    private var elapsedTime = 0.0
    private var previousCandidateTime: Double?
    private var rhythmicCandidates = 0

    /// Processes a single acceleration sample, returning the steps newly
    /// credited by it (zero, one, or the retroactive warm-up credit).
    mutating func process(magnitude: Double, dt: Double) -> Int {
        elapsedTime += max(dt, 0)
        let clamped = max(magnitude, 0)
        fast += Self.fastAlpha * (clamped - fast)
        slow += Self.slowAlpha * (clamped - slow)
        let deviation = fast - slow

        if deviation <= Self.fallThreshold {
            isArmed = true
        }

        guard isArmed, deviation >= Self.riseThreshold else {
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
        fast = 0
        slow = 0
        isArmed = true
        elapsedTime = 0
        previousCandidateTime = nil
        rhythmicCandidates = 0
    }
}
