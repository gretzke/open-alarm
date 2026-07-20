import AlarmKit
import XCTest

@testable import OpenAlarm

@MainActor
final class WakeCheckMidSessionModificationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "openalarm-wake-check-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testUnskipMidSessionLeavesCanonicalIDUntouched() async throws {
        let alarm = makeAlarm(overrideKind: .skipNext)
        let (store, manager, _) = makeStore(alarm: alarm, withSession: true)

        try await store.setAlarmEnabled(alarm, enabled: true)

        XCTAssertFalse(manager.touchedIDs.contains(alarm.id))
        XCTAssertEqual(store.runtimePhases[alarm.id], .awaitingWakeCheck)
    }

    func testSkipNextMidSessionLeavesCanonicalIDUntouched() async throws {
        let alarm = makeAlarm()
        let (store, manager, _) = makeStore(alarm: alarm, withSession: true)

        try await store.setAlarmEnabled(alarm, enabled: false, skipNext: true)

        XCTAssertFalse(manager.touchedIDs.contains(alarm.id))
        XCTAssertEqual(store.runtimePhases[alarm.id], .awaitingWakeCheck)
    }

    func testEditMidSessionLeavesCanonicalIDUntouchedAndPreservesLifecycleState() async throws {
        let alarm = makeAlarm()
        let (store, manager, _) = makeStore(alarm: alarm, withSession: true)
        var draft = AlarmDraft(alarm: alarm)
        draft.name = "Edited"

        try await store.updateAlarm(alarm, with: draft)

        XCTAssertFalse(manager.touchedIDs.contains(alarm.id))
        XCTAssertEqual(store.alarms.first?.lifecycleState, .awaitingWakeCheck)
        XCTAssertTrue(store.wakeCheckSessions[alarm.id]?.modifiedDuringSession == true)
    }

    func testDisableMidSessionThenConfirmDoesNotSchedule() async throws {
        let alarm = makeAlarm()
        let (store, manager, _) = makeStore(alarm: alarm, withSession: true)

        try await store.setAlarmEnabled(alarm, enabled: false)
        await store.confirmWakeUpCheck(for: alarm.id)

        XCTAssertTrue(manager.scheduledIDs.isEmpty)
    }

    func testDisableWithOverrideAfterReadFailureCancelsCanonicalAndBridges() async throws {
        let alarm = makeAlarm(overrideKind: .skipNext)
        let (store, manager, _) = makeStore(alarm: alarm, withSession: false, alarmsReadFails: true)

        try await store.setAlarmEnabled(alarm, enabled: false)

        XCTAssertTrue(manager.cancelIDs.contains(alarm.id))
        XCTAssertTrue(Set(alarm.activeOverride!.bridgeAlarmIDs).isSubset(of: Set(manager.cancelIDs)))
    }

    func testDisableWithSessionAfterReadFailureCancelsBridgesButNotBackup() async throws {
        let alarm = makeAlarm(overrideKind: .skipNext)
        let (store, manager, _) = makeStore(alarm: alarm, withSession: true, alarmsReadFails: true)

        try await store.setAlarmEnabled(alarm, enabled: false)

        XCTAssertFalse(manager.touchedIDs.contains(alarm.id))
        XCTAssertTrue(Set(alarm.activeOverride!.bridgeAlarmIDs).isSubset(of: Set(manager.cancelIDs)))
        XCTAssertEqual(store.runtimePhases[alarm.id], .awaitingWakeCheck)
    }

    func testDisabledEditWithSessionAfterReadFailureLeavesBackupUntouched() async throws {
        var alarm = makeAlarm(overrideKind: .skipNext)
        alarm.isEnabled = false
        let (store, manager, _) = makeStore(alarm: alarm, withSession: true, alarmsReadFails: true)
        var draft = AlarmDraft(alarm: alarm)
        draft.name = "Edited"

        try await store.updateAlarm(alarm, with: draft)

        XCTAssertFalse(manager.touchedIDs.contains(alarm.id))
        XCTAssertEqual(store.runtimePhases[alarm.id], .awaitingWakeCheck)
        XCTAssertTrue(Set(alarm.activeOverride!.bridgeAlarmIDs).isSubset(of: Set(manager.cancelIDs)))
    }

    func testUpdateAlarmCancelsBothCallerAndCurrentModelBridges() async throws {
        var alarm = makeAlarm(overrideKind: .skipNext)
        alarm.lifecycleState = .scheduled
        let (store, manager, _) = makeStore(alarm: alarm, withSession: false)

        // Caller holds a stale copy whose override carries different bridge IDs.
        var staleCopy = alarm
        let staleBridgeIDs = [UUID(), UUID()]
        staleCopy.activeOverride = OverrideState(
            kind: .skipNext,
            bridgeAlarmIDs: staleBridgeIDs,
            restoreAnchorDate: .now.addingTimeInterval(3_600)
        )
        var draft = AlarmDraft(alarm: staleCopy)
        draft.name = "Edited"

        try await store.updateAlarm(staleCopy, with: draft)

        let expected = Set(alarm.activeOverride!.bridgeAlarmIDs).union(staleBridgeIDs)
        XCTAssertTrue(expected.isSubset(of: Set(manager.cancelIDs)))
    }

    func testForceRescheduleCancelsBothCallerAndCurrentModelBridges() async {
        var alarm = makeAlarm(overrideKind: .skipNext)
        alarm.lifecycleState = .scheduled
        let (store, manager, _) = makeStore(alarm: alarm, withSession: false)

        var staleCopy = alarm
        let staleBridgeIDs = [UUID(), UUID()]
        staleCopy.activeOverride = OverrideState(
            kind: .skipNext,
            bridgeAlarmIDs: staleBridgeIDs,
            restoreAnchorDate: .now.addingTimeInterval(3_600)
        )

        await store.forceRescheduleAlarm(staleCopy)

        let expected = Set(alarm.activeOverride!.bridgeAlarmIDs).union(staleBridgeIDs)
        XCTAssertTrue(expected.isSubset(of: Set(manager.cancelIDs)))
    }

    func testDisableWithOverrideDuringSessionCancelsBridgesButNotBackup() async throws {
        let alarm = makeAlarm(overrideKind: .skipNext)
        let (store, manager, _) = makeStore(alarm: alarm, withSession: true)

        try await store.setAlarmEnabled(alarm, enabled: false)

        XCTAssertFalse(manager.touchedIDs.contains(alarm.id))
        XCTAssertTrue(Set(alarm.activeOverride!.bridgeAlarmIDs).isSubset(of: Set(manager.cancelIDs)))
    }

    func testConfirmModifiedOneShotSchedulesCanonicalAlarm() async {
        var alarm = makeAlarm(repeating: false)
        alarm.deleteAfterUse = false
        let (store, manager, _) = makeStore(alarm: alarm, withSession: true, modifiedDuringSession: true)

        await store.confirmWakeUpCheck(for: alarm.id)

        XCTAssertTrue(manager.scheduledIDs.contains(alarm.id))
    }

    func testForceRescheduleSkipsSessionHoldingAlarm() async {
        let alarm = makeAlarm()
        let (store, manager, _) = makeStore(alarm: alarm, withSession: true)

        await store.forceRescheduleAlarm(alarm)

        XCTAssertFalse(manager.touchedIDs.contains(alarm.id))
        XCTAssertTrue(store.wakeCheckSessions[alarm.id]?.modifiedDuringSession == true)
    }

    func testRebuildRuntimePhasesHealsAwaitingWakeCheckWithoutSession() {
        let alarm = makeAlarm()
        let (store, _, _) = makeStore(alarm: alarm, withSession: false)

        store.rebuildRuntimePhases()

        XCTAssertEqual(store.alarms.first?.lifecycleState, .scheduled)
        XCTAssertEqual(store.runtimePhases[alarm.id], .idle)
    }

    func testDeleteDuringWakeCheckStartupCancelsLateScheduledBackup() async {
        let alarm = makeAlarm()
        let (store, manager, _) = makeStore(alarm: alarm, withSession: false)
        manager.holdSchedules = true
        let scheduled = expectation(description: "backup schedule started")
        manager.onScheduleStarted = { scheduled.fulfill() }

        let task = Task { @MainActor in
            await store.startWakeCheckSession(
                for: alarm.id,
                alarm: alarm,
                settings: SharedAlarmSettings.featureDefaults
            )
        }
        await fulfillment(of: [scheduled], timeout: 1)

        store.deleteAlarm(alarm)
        manager.resumeSchedule()
        await task.value

        XCTAssertGreaterThanOrEqual(manager.stopIDs.filter { $0 == alarm.id }.count, 2)
        XCTAssertGreaterThanOrEqual(manager.cancelIDs.filter { $0 == alarm.id }.count, 2)
    }

    func testGlobalKillSwitchReArmsEnabledAlarmBeforeReturning() async {
        let alarm = makeAlarm()
        let (store, manager, _) = makeStore(alarm: alarm, withSession: true)

        await store.disableWakeUpCheckFeatureGlobally()

        XCTAssertTrue(manager.stopIDs.contains(alarm.id))
        XCTAssertTrue(manager.cancelIDs.contains(alarm.id))
        XCTAssertTrue(manager.scheduledIDs.contains(alarm.id))
        XCTAssertTrue(store.wakeCheckSessions.isEmpty)
        XCTAssertEqual(store.alarms.first?.lifecycleState, .scheduled)
    }

    func testLateBackupWriteAfterSessionEndedIsReconciled() async throws {
        let alarm = makeAlarm()
        let (store, manager, _) = makeStore(alarm: alarm, withSession: false)
        manager.holdSchedules = true
        let scheduled = expectation(description: "backup schedule started")
        manager.onScheduleStarted = { scheduled.fulfill() }

        let task = Task { @MainActor in
            await store.startWakeCheckSession(
                for: alarm.id,
                alarm: alarm,
                settings: SharedAlarmSettings.featureDefaults
            )
        }
        await fulfillment(of: [scheduled], timeout: 1)

        // Session ends while the backup registration is still in flight: the
        // alarm is disabled and the check confirmed, so the late write must be
        // detected and the stale backup removed from AlarmKit.
        try await store.setAlarmEnabled(alarm, enabled: false)
        await store.confirmWakeUpCheck(for: alarm.id)
        let stopsBefore = manager.stopIDs.filter { $0 == alarm.id }.count
        let cancelsBefore = manager.cancelIDs.filter { $0 == alarm.id }.count

        manager.resumeSchedule()
        await task.value

        XCTAssertGreaterThan(manager.stopIDs.filter { $0 == alarm.id }.count, stopsBefore)
        XCTAssertGreaterThan(manager.cancelIDs.filter { $0 == alarm.id }.count, cancelsBefore)
    }

    private func makeStore(
        alarm: UserAlarm,
        withSession: Bool,
        modifiedDuringSession: Bool = false,
        alarmsReadFails: Bool = false
    ) -> (AlarmStore, FakeAlarmManager, FakeWakeCheckNotificationService) {
        let persistence = AlarmPersistence(defaults: defaults)
        persistence.saveUserAlarms([alarm])
        if withSession {
            let session = WakeCheckSession(
                alarmID: alarm.id,
                cycle: 1,
                checkAt: .now,
                deadlineAt: .now.addingTimeInterval(60),
                notificationID: WakeUpCheckNotificationConstants.notificationID(alarmID: alarm.id, cycle: 1),
                modifiedDuringSession: modifiedDuringSession
            )
            persistence.saveWakeCheckSessions([alarm.id: session])
        }

        let manager = FakeAlarmManager()
        manager.alarmsReadFails = alarmsReadFails
        let notifications = FakeWakeCheckNotificationService()
        let store = AlarmStore(
            alarmManager: manager,
            userDefaults: defaults,
            wakeCheckNotificationService: notifications
        )
        store.permissionStatus = .authorized
        return (store, manager, notifications)
    }

    private func makeAlarm(
        repeating: Bool = true,
        overrideKind: OverrideKind? = nil
    ) -> UserAlarm {
        let id = UUID()
        let bridgeIDs = [UUID(), UUID()]
        return UserAlarm(
            id: id,
            trigger: .time(hour: 7, minute: 0),
            recurrence: repeating ? .weekly([.monday]) : .none,
            deleteAfterUse: false,
            activeOverride: overrideKind.map {
                OverrideState(kind: $0, bridgeAlarmIDs: bridgeIDs, restoreAnchorDate: .now.addingTimeInterval(3_600))
            },
            lifecycleState: .awaitingWakeCheck
        )
    }
}

@MainActor
private final class FakeAlarmManager: AlarmManagerScheduling {
    private enum TestError: Error { case scheduleFailed, alarmsReadFailed }

    var scheduledIDs: [UUID] = []
    var stopIDs: [UUID] = []
    var cancelIDs: [UUID] = []
    var holdSchedules = false
    var alarmsReadFails = false
    var onScheduleStarted: (() -> Void)?
    private var scheduleContinuation: CheckedContinuation<Void, Never>?

    var touchedIDs: [UUID] { scheduledIDs + stopIDs + cancelIDs }
    var alarms: [Alarm] {
        get throws {
            if alarmsReadFails { throw TestError.alarmsReadFailed }
            return []
        }
    }

    func alarmUpdatesForStore() -> AsyncStream<[Alarm]>? { nil }

    func schedule(
        id: UUID,
        configuration: AlarmManager.AlarmConfiguration<OpenAlarmMetadata>
    ) async throws -> Alarm {
        scheduledIDs.append(id)
        if holdSchedules {
            await withCheckedContinuation { continuation in
                scheduleContinuation = continuation
                onScheduleStarted?()
            }
        }
        throw TestError.scheduleFailed
    }

    func stop(id: UUID) throws {
        stopIDs.append(id)
    }

    func cancel(id: UUID) throws {
        cancelIDs.append(id)
    }

    func resumeSchedule() {
        scheduleContinuation?.resume()
        scheduleContinuation = nil
    }
}

@MainActor
private final class FakeWakeCheckNotificationService: WakeUpCheckNotificationServicing {
    var scheduledIDs: [String] = []
    var cancelledIDs: [String] = []

    func scheduleWakeCheckNotification(
        alarmID: UUID,
        cycle: Int,
        triggerDate: Date,
        shouldSchedule: @escaping @MainActor () -> Bool
    ) async {
        guard shouldSchedule() else { return }
        scheduledIDs.append(WakeUpCheckNotificationConstants.notificationID(alarmID: alarmID, cycle: cycle))
    }

    func cancelNotification(id: String) {
        cancelledIDs.append(id)
    }

    func ensureCategoryRegistered() {}
}
