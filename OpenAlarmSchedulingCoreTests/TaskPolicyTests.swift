import XCTest
@testable import OpenAlarmSchedulingCore

final class TaskPolicyTests: XCTestCase {
    func testEffectiveTasksEmptyWhenSettingsDisableTasks() {
        let persistence = AlarmPersistence(defaults: .standard)
        var settings = SharedAlarmSettings.featureDefaults
        settings.tasksEnabled = false
        settings.tasks = [.math(difficulty: .medium, count: 3), .dummy]

        XCTAssertEqual(persistence.effectiveTasks(from: settings), [])
    }

    func testEffectiveTasksPassThroughWhenSettingsEnableTasks() {
        let persistence = AlarmPersistence(defaults: .standard)
        var settings = SharedAlarmSettings.featureDefaults
        settings.tasksEnabled = true
        settings.tasks = [.math(difficulty: .medium, count: 3), .dummy]

        XCTAssertEqual(persistence.effectiveTasks(from: settings), settings.tasks)
    }

    func testLegacySettingsWithoutTasksEnabledDecodeAsEnabled() throws {
        let json = """
        {
          "snoozeEnabled": false,
          "snoozeDurationMinutes": 5,
          "maxSnoozes": 3,
          "wakeUpCheckEnabled": false,
          "wakeUpCheckDelayMinutes": 5,
          "wakeUpCheckResponseTimeoutMinutes": 3,
          "tasks": [],
          "volume": { "targetPercent": 20 }
        }
        """.data(using: .utf8)!

        XCTAssertTrue(try JSONDecoder().decode(SharedAlarmSettings.self, from: json).tasksEnabled)
    }

    func testTasksEnabledRoundTripsThroughCodable() throws {
        var settings = SharedAlarmSettings.featureDefaults
        settings.tasksEnabled = false

        let decoded = try JSONDecoder().decode(
            SharedAlarmSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertFalse(decoded.tasksEnabled)
    }

    func testPersistenceRoundTripUsesSavedTasksEnabledSetting() {
        let suiteName = "TaskPolicyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = SharedAlarmSettings.featureDefaults
        settings.tasksEnabled = false
        settings.tasks = [.math(difficulty: .medium, count: 3)]

        AlarmPersistence(defaults: defaults).saveDefaultSharedSettings(settings)

        let loaded = AlarmPersistence(defaults: defaults).loadDefaultSharedSettings()
        XCTAssertEqual(AlarmPersistence(defaults: defaults).effectiveTasks(from: loaded), [])
    }
}
