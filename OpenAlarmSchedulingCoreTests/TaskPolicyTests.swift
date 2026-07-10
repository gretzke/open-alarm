import XCTest
@testable import OpenAlarmSchedulingCore

final class TaskPolicyTests: XCTestCase {
    private var persistence: AlarmPersistence!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "TaskPolicyTests")!
        defaults.removePersistentDomain(forName: "TaskPolicyTests")
        persistence = AlarmPersistence(defaults: defaults)
    }

    func testTasksEnabledDefaultsTrueWhenKeyMissing() {
        XCTAssertTrue(persistence.loadTasksEnabled())
    }

    func testTasksEnabledRoundTrip() {
        persistence.saveTasksEnabled(false)
        XCTAssertFalse(persistence.loadTasksEnabled())
        persistence.saveTasksEnabled(true)
        XCTAssertTrue(persistence.loadTasksEnabled())
    }

    func testEffectiveTasksPassthroughWhenEnabled() {
        var settings = SharedAlarmSettings.featureDefaults
        settings.tasks = [.math(difficulty: .simple, count: 3)]
        XCTAssertEqual(persistence.effectiveTasks(from: settings), settings.tasks)
    }

    func testEffectiveTasksEmptyWhenDisabled() {
        var settings = SharedAlarmSettings.featureDefaults
        settings.tasks = [.math(difficulty: .simple, count: 3), .dummy]
        persistence.saveTasksEnabled(false)
        XCTAssertEqual(persistence.effectiveTasks(from: settings), [])
    }
}
