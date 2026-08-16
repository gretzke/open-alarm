import Foundation
import Testing
@testable import OpenAlarmSchedulingCore

struct LastRingtoneStoreTests {
    @Test func setGetClearRoundTrip() {
        let suiteName = "LastRingtoneStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let alarmID = UUID()

        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        LastRingtoneStore.set("nature.rain", forAlarm: alarmID, defaults: defaults)
        #expect(LastRingtoneStore.lastRingtoneID(forAlarm: alarmID, defaults: defaults) == "nature.rain")

        LastRingtoneStore.clear(forAlarm: alarmID, defaults: defaults)
        #expect(LastRingtoneStore.lastRingtoneID(forAlarm: alarmID, defaults: defaults) == nil)
    }
}
