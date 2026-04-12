import ActivityKit
import Foundation

struct NapCountdownLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var endDate: Date?
        var pausedRemainingSeconds: Int?
        var isSnoozing: Bool
        var isPaused: Bool
    }

    var napID: String
}
