import XCTest
@testable import OpenAlarmSchedulingCore

final class SharedAlarmSettingsTests: XCTestCase {
    func testDecodingMissingVolumeUsesDefaultTaskAlarmVolume() throws {
        let json = """
        {
          "snoozeEnabled": false,
          "snoozeDurationMinutes": 5,
          "maxSnoozes": 3,
          "wakeUpCheckEnabled": false,
          "wakeUpCheckDelayMinutes": 5,
          "wakeUpCheckResponseTimeoutMinutes": 3,
          "tasks": []
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(SharedAlarmSettings.self, from: json)

        XCTAssertEqual(settings.volume, .default)
        XCTAssertEqual(settings.volume.targetPercent, 20)
        XCTAssertEqual(settings.volume.targetScalar, 0.2, accuracy: 0.001)
    }

    func testVolumePercentIsClampedToValidRange() {
        XCTAssertEqual(AlarmVolumeSettings(targetPercent: -10).targetPercent, 0)
        XCTAssertEqual(AlarmVolumeSettings(targetPercent: 120).targetPercent, 100)
    }
}
