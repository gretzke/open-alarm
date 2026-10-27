import Foundation

enum NapDawnProgress {
    /// Use the final five minutes, or the entire nap when it is shorter.
    static func value(remainingSeconds: TimeInterval, durationSeconds: TimeInterval, isPaused: Bool, isSnoozing: Bool) -> Double {
        guard !isPaused, !isSnoozing, durationSeconds > 0,
              remainingSeconds.isFinite, durationSeconds.isFinite else { return 0 }
        let window = min(300, durationSeconds)
        return min(max(1 - remainingSeconds / window, 0), 1)
    }
}
