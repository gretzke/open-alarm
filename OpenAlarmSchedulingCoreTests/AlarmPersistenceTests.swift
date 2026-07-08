import XCTest
@testable import OpenAlarmSchedulingCore

final class AlarmPersistenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var persistence: AlarmPersistence!

    override func setUp() {
        super.setUp()
        suiteName = "openalarm-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        persistence = AlarmPersistence(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Round trips (R-14.1)

    func testSaveLoadRoundTrip() {
        let alarms = [
            AlarmDefinition(name: "One", trigger: .time(hour: 6, minute: 0)),
            AlarmDefinition(
                name: "Two",
                trigger: .time(hour: 7, minute: 30),
                recurrence: .weekly([.monday]),
                deleteAfterUse: false
            ),
        ]
        persistence.saveUserAlarms(alarms)
        XCTAssertEqual(persistence.loadUserAlarms(), alarms)
    }

    func testEmptyStoreLoadsEmpty() {
        XCTAssertEqual(persistence.loadUserAlarms(), [])
    }

    func testCorruptDefaultSettingsFallBackToFeatureDefaults() {
        defaults.set(Data("garbage".utf8), forKey: "OPENALARM_DEFAULT_SHARED_SETTINGS_V1")
        XCTAssertEqual(persistence.loadDefaultSharedSettings(), .featureDefaults)
    }

    func testWakeCheckSessionsRoundTrip() {
        let session = WakeCheckSession(
            alarmID: UUID(),
            cycle: 2,
            checkAt: Date(timeIntervalSinceReferenceDate: 1_000),
            deadlineAt: Date(timeIntervalSinceReferenceDate: 1_180),
            notificationID: "wakecheck.test.2"
        )
        persistence.saveWakeCheckSessions([session.alarmID: session])
        XCTAssertEqual(persistence.loadWakeCheckSessions(), [session.alarmID: session])
    }

    func testPendingDisarmIDsRoundTrip() {
        let ids: Set<UUID> = [UUID(), UUID()]
        persistence.savePendingDisarmAlarmIDs(ids)
        XCTAssertEqual(persistence.loadPendingDisarmAlarmIDs(), ids)
    }

    // MARK: - Non-destructive recovery (D-2)

    func testCorruptAlarmBlobIsQuarantinedNotLost() {
        defaults.set(Data("not json".utf8), forKey: "OPENALARM_USER_ALARMS_V1")

        let loaded = persistence.loadUserAlarms()

        XCTAssertEqual(loaded, [])
        XCTAssertEqual(
            defaults.data(forKey: "OPENALARM_USER_ALARMS_CORRUPT_V1"),
            Data("not json".utf8),
            "original bytes must be preserved for recovery"
        )
        XCTAssertNotNil(
            defaults.data(forKey: "OPENALARM_USER_ALARMS_V1"),
            "source key must stay untouched until a successful save overwrites it"
        )
    }

    func testQuarantineDoesNotOverwriteEarlierQuarantine() {
        defaults.set(Data("first".utf8), forKey: "OPENALARM_USER_ALARMS_CORRUPT_V1")
        defaults.set(Data("second".utf8), forKey: "OPENALARM_USER_ALARMS_V1")

        _ = persistence.loadUserAlarms()

        XCTAssertEqual(
            defaults.data(forKey: "OPENALARM_USER_ALARMS_CORRUPT_V1"),
            Data("first".utf8)
        )
    }
}
