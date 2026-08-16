import Foundation
import Testing
@testable import OpenAlarmSchedulingCore

struct RingtoneShuffleTests {
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state = 2_862_933_555_777_941_757 &* state &+ 3_037_000_493
            return state
        }
    }

    @Test func legacySettingsDecodeToSingleSelection() throws {
        let encoded = try JSONEncoder().encode(SharedAlarmSettings.featureDefaults)
        var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        payload.removeValue(forKey: "ringtoneShuffleEnabled")
        payload.removeValue(forKey: "ringtoneIDs")

        let legacyData = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(SharedAlarmSettings.self, from: legacyData)

        #expect(decoded.ringtoneShuffleEnabled == false)
        #expect(decoded.ringtoneIDs == [decoded.ringtoneID])
    }

    @Test func decodingAddsRingtoneIDToSelections() throws {
        let encoded = try JSONEncoder().encode(SharedAlarmSettings.featureDefaults)
        var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        payload["ringtoneID"] = "nature.rain"
        payload["ringtoneIDs"] = ["dawn.morning"]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(SharedAlarmSettings.self, from: data)

        #expect(decoded.ringtoneIDs == ["dawn.morning", "nature.rain"])
    }

    @Test func disablingShuffleKeepsLastSelectedTone() {
        var settings = SharedAlarmSettings.featureDefaults
        settings.setRingtoneShuffleEnabled(true)
        settings.selectRingtone("nature.rain")
        settings.selectRingtone("dawn.morning")

        settings.setRingtoneShuffleEnabled(false)

        #expect(settings.ringtoneID == "dawn.morning")
        #expect(settings.ringtoneIDs == ["dawn.morning"])
    }

    @Test func shuffleDoesNotRemoveItsOnlySelection() {
        var settings = SharedAlarmSettings.featureDefaults
        settings.setRingtoneShuffleEnabled(true)

        settings.selectRingtone(RingtoneCatalog.defaultToneID)

        #expect(settings.ringtoneIDs == [RingtoneCatalog.defaultToneID])
    }

    @Test func randomSelectionExcludesPreviousToneWhenAlternativesExist() {
        let ids = ["nature.rain", "dawn.morning", "energetic.newerwave"]

        for seed in 1...100 {
            var generator = SeededGenerator(seed: UInt64(seed))
            let selection = RingtoneCatalog.randomSelectionID(
                from: ids,
                excluding: "dawn.morning",
                using: &generator
            )
            #expect(selection != "dawn.morning")
            #expect(ids.contains(selection))
        }
    }

    @Test func wakeCheckSessionKeepsOccurrenceTone() throws {
        let ringtoneID = "dawn.morning"
        let session = WakeCheckSession(
            alarmID: UUID(),
            cycle: 1,
            checkAt: .now,
            deadlineAt: .now.addingTimeInterval(60),
            notificationID: "wake-check",
            ringtoneID: ringtoneID
        )

        let decoded = try JSONDecoder().decode(
            WakeCheckSession.self,
            from: JSONEncoder().encode(session)
        )

        #expect(decoded.ringtoneID == ringtoneID)
    }
}
