import XCTest
@testable import OpenAlarmSchedulingCore

final class SharedAlarmSettingsRingtoneTests: XCTestCase {
    func testLegacyPayloadWithoutRingtoneIDDecodesToDefault() throws {
        let encoded = try JSONEncoder().encode(SharedAlarmSettings.featureDefaults)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        payload.removeValue(forKey: "ringtoneID")

        let legacyData = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(SharedAlarmSettings.self, from: legacyData)

        XCTAssertEqual(decoded.ringtoneID, RingtoneCatalog.defaultToneID)
    }

    func testCustomRingtoneIDRoundTrips() throws {
        var settings = SharedAlarmSettings.featureDefaults
        settings.ringtoneID = "nature.placeholder"

        let decoded = try JSONDecoder().decode(
            SharedAlarmSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertEqual(decoded.ringtoneID, "nature.placeholder")
    }

    func testResolvedSharedSettingsKeepsExistingSettingsModeSemantics() {
        var defaults = SharedAlarmSettings.featureDefaults
        defaults.ringtoneID = "dawn.placeholder"
        var custom = SharedAlarmSettings.featureDefaults
        custom.ringtoneID = "energetic.placeholder"

        let customDraft = AlarmDraft(
            useDefaultSharedSettings: false,
            customSharedSettings: custom
        )
        let defaultDraft = AlarmDraft(
            useDefaultSharedSettings: true,
            customSharedSettings: custom
        )

        XCTAssertEqual(customDraft.resolvedSharedSettings(defaults: defaults).ringtoneID, custom.ringtoneID)
        XCTAssertEqual(defaultDraft.resolvedSharedSettings(defaults: defaults).ringtoneID, defaults.ringtoneID)
    }
}
