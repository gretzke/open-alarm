import AlarmKit
import XCTest

@testable import OpenAlarm

@MainActor
final class AlarmLifecycleRegressionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "openalarm-lifecycle-regression-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testNapDeleteClearsPendingDisarmAndBackstop() async {
        let nap = makeAlarm(type: .nap(NapConfig(durationMinutes: 10, pausedRemainingSeconds: nil)))
        let backstopID = UUID()
        let persistence = AlarmPersistence(defaults: defaults)
        persistence.saveUserAlarms([nap])
        persistence.savePendingDisarmAlarmIDs([nap.id])
        persistence.saveWakeCheckSessions([
            nap.id: WakeCheckSession(
                alarmID: nap.id,
                cycle: 1,
                checkAt: .now,
                deadlineAt: .now.addingTimeInterval(60),
                notificationID: WakeUpCheckNotificationConstants.notificationID(alarmID: nap.id, cycle: 1)
            )
        ])
        persistence.savePendingWakeUpCheckShowConfirmUIIDs([nap.id])
        BackstopSlotStore.set(backstopID: backstopID, forParent: nap.id, defaults: defaults)
        let manager = LifecycleFakeAlarmManager()

        await NapDeleteIntent.delete(
            napID: nap.id,
            persistence: persistence,
            alarmManager: manager,
            defaults: defaults
        )

        XCTAssertFalse(persistence.loadPendingDisarmAlarmIDs().contains(nap.id))
        XCTAssertNil(persistence.loadWakeCheckSessions()[nap.id])
        XCTAssertFalse(persistence.loadPendingWakeUpCheckShowConfirmUIIDs().contains(nap.id))
        XCTAssertNil(BackstopSlotStore.backstopID(forParent: nap.id, defaults: defaults))
        XCTAssertTrue(manager.stopIDs.contains(backstopID))
        XCTAssertTrue(manager.cancelIDs.contains(backstopID))
    }

    func testMaxSnoozeFallbackRetriesBackstopAndRetainsPreviousSlotOnFailure() async {
        let alarm = makeAlarm(
            snoozeCount: 1,
            settings: settings(tasks: [.dummy], maxSnoozes: 1)
        )
        let previousBackstopID = UUID()
        let persistence = AlarmPersistence(defaults: defaults)
        persistence.saveUserAlarms([alarm])
        BackstopSlotStore.set(backstopID: previousBackstopID, forParent: alarm.id, defaults: defaults)
        let manager = LifecycleFakeAlarmManager(scheduleFails: true)

        await SnoozeIntent.routeLimitReachedToDisarm(
            intentID: alarm.id,
            alarms: [alarm],
            persistence: persistence,
            alarmManager: manager,
            defaults: defaults
        )

        XCTAssertEqual(manager.scheduledIDs.count, 2)
        XCTAssertEqual(BackstopSlotStore.backstopID(forParent: alarm.id, defaults: defaults), previousBackstopID)
    }

    func testFailedFirstRollingScheduleKeepsAdoptedOrphan() async {
        let alarm = makeAlarm()
        let orphanID = UUID()
        let orphanFireDate = Date(timeIntervalSinceReferenceDate: 123_456)
        BackstopSlotStore.set(backstopID: orphanID, forParent: alarm.id, defaults: defaults)
        AlertReferenceStore(defaults: defaults).record(
            AlertReference(
                expectedFireDate: orphanFireDate,
                ringtoneID: "classic.default",
                parentAlarmID: alarm.id
            ),
            alarmKitID: alarm.id
        )
        let manager = LifecycleFakeAlarmManager(scheduleFails: true)
        let forceClose = ForceCloseAlarmManager(
            alarm: alarm,
            resolvedSettings: settings(),
            alarmManager: manager,
            defaults: defaults
        )

        forceClose.start(replacingOrphanID: orphanID)
        await yieldUntilScheduleAttempt(manager)

        XCTAssertFalse(manager.stopIDs.contains(orphanID))
        XCTAssertFalse(manager.cancelIDs.contains(orphanID))
        XCTAssertEqual(BackstopSlotStore.backstopID(forParent: alarm.id, defaults: defaults), orphanID)
        XCTAssertEqual(
            AlertReferenceStore(defaults: defaults).reference(alarmKitID: alarm.id)?.expectedFireDate,
            orphanFireDate
        )
        forceClose.suspend()
    }

    func testFailedFirstRollingScheduleDoesNotMutateExistingSlot() async {
        let alarm = makeAlarm()
        let existingID = UUID()
        BackstopSlotStore.set(backstopID: existingID, forParent: alarm.id, defaults: defaults)
        let manager = LifecycleFakeAlarmManager(scheduleFails: true)
        let forceClose = ForceCloseAlarmManager(
            alarm: alarm,
            resolvedSettings: settings(),
            alarmManager: manager,
            defaults: defaults
        )

        forceClose.start()
        await yieldUntilScheduleAttempt(manager)

        XCTAssertEqual(BackstopSlotStore.backstopID(forParent: alarm.id, defaults: defaults), existingID)
        forceClose.suspend()
    }

    func testStopRetainsSlotWhenBothCancellationAttemptsFail() {
        let alarm = makeAlarm()
        let backstopID = UUID()
        BackstopSlotStore.set(backstopID: backstopID, forParent: alarm.id, defaults: defaults)
        let manager = LifecycleFakeAlarmManager(stopFails: true, cancelFails: true)
        let forceClose = ForceCloseAlarmManager(
            alarm: alarm,
            resolvedSettings: settings(),
            alarmManager: manager,
            defaults: defaults
        )
        forceClose.adoptForTesting(currentID: backstopID, fireDate: .now)

        forceClose.stop()

        XCTAssertEqual(BackstopSlotStore.backstopID(forParent: alarm.id, defaults: defaults), backstopID)
        XCTAssertEqual(manager.stopIDs.filter { $0 == backstopID }.count, 2)
        XCTAssertEqual(manager.cancelIDs.filter { $0 == backstopID }.count, 2)
    }

    func testStopClearsSlotWhenCancellationSucceeds() {
        let alarm = makeAlarm()
        let backstopID = UUID()
        BackstopSlotStore.set(backstopID: backstopID, forParent: alarm.id, defaults: defaults)
        let manager = LifecycleFakeAlarmManager()
        let forceClose = ForceCloseAlarmManager(
            alarm: alarm,
            resolvedSettings: settings(),
            alarmManager: manager,
            defaults: defaults
        )
        forceClose.adoptForTesting(currentID: backstopID, fireDate: .now)

        forceClose.stop()

        XCTAssertNil(BackstopSlotStore.backstopID(forParent: alarm.id, defaults: defaults))
    }

    func testFailedRollingScheduleRestoresAdoptedRegistrationFireDate() async {
        let alarm = makeAlarm()
        let fireDate = Date(timeIntervalSinceReferenceDate: 123_456)
        let orphanID = UUID()
        BackstopSlotStore.set(backstopID: orphanID, forParent: alarm.id, defaults: defaults)
        AlertReferenceStore(defaults: defaults).record(
            AlertReference(
                expectedFireDate: fireDate,
                ringtoneID: "classic.default",
                parentAlarmID: alarm.id
            ),
            alarmKitID: alarm.id
        )
        let manager = LifecycleFakeAlarmManager(scheduleFails: true)
        let forceClose = ForceCloseAlarmManager(
            alarm: alarm,
            resolvedSettings: settings(),
            alarmManager: manager,
            defaults: defaults
        )

        forceClose.start(replacingOrphanID: orphanID)
        await yieldUntilScheduleAttempt(manager)

        XCTAssertEqual(
            AlertReferenceStore(defaults: defaults).reference(alarmKitID: alarm.id)?.expectedFireDate,
            fireDate
        )
        forceClose.suspend()
    }

    private func yieldUntilScheduleAttempt(_ manager: LifecycleFakeAlarmManager) async {
        for _ in 0..<20 where manager.scheduledIDs.isEmpty {
            await Task.yield()
        }
        XCTAssertFalse(manager.scheduledIDs.isEmpty)
    }

    private func makeAlarm(
        type: AlarmType = .regular,
        snoozeCount: Int = 0,
        settings: SharedAlarmSettings? = nil
    ) -> AlarmDefinition {
        AlarmDefinition(
            trigger: .time(hour: 7, minute: 0),
            type: type,
            deleteAfterUse: false,
            settingsMode: settings.map(SettingsMode.custom) ?? .useDefault,
            snoozeCount: snoozeCount
        )
    }

    private func settings(
        tasks: [AlarmTask] = [],
        maxSnoozes: Int? = 3
    ) -> SharedAlarmSettings {
        SharedAlarmSettings(
            snoozeEnabled: true,
            snoozeDurationMinutes: 5,
            maxSnoozes: maxSnoozes,
            wakeUpCheckEnabled: false,
            wakeUpCheckDelayMinutes: 5,
            wakeUpCheckResponseTimeoutMinutes: 2,
            tasksEnabled: true,
            tasks: tasks
        )
    }
}

@MainActor
private final class LifecycleFakeAlarmManager: AlarmManagerScheduling {
    private enum Failure: Error { case schedule, stop, cancel }

    var scheduledIDs: [UUID] = []
    var stopIDs: [UUID] = []
    var cancelIDs: [UUID] = []
    private let scheduleFails: Bool
    private let stopFails: Bool
    private let cancelFails: Bool

    init(scheduleFails: Bool = false, stopFails: Bool = false, cancelFails: Bool = false) {
        self.scheduleFails = scheduleFails
        self.stopFails = stopFails
        self.cancelFails = cancelFails
    }

    var alarms: [Alarm] { get throws { [] } }

    func alarmUpdatesForStore() -> AsyncStream<[Alarm]>? { nil }

    func schedule(
        id: UUID,
        configuration: AlarmManager.AlarmConfiguration<OpenAlarmMetadata>
    ) async throws -> Alarm {
        scheduledIDs.append(id)
        if scheduleFails { throw Failure.schedule }
        throw Failure.schedule // AlarmKit.Alarm cannot be constructed in tests.
    }

    func stop(id: UUID) throws {
        stopIDs.append(id)
        if stopFails { throw Failure.stop }
    }

    func cancel(id: UUID) throws {
        cancelIDs.append(id)
        if cancelFails { throw Failure.cancel }
    }
}
