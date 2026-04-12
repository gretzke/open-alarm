import ActivityKit
import Foundation

struct AlarmSoundLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var alarmName: String
    }

    var alarmID: String
}
