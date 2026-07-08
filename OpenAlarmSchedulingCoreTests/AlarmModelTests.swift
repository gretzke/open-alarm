import XCTest
@testable import OpenAlarmSchedulingCore

/// Characterization tests for the model layer, pinned to the behavior catalog in
/// docs/scheduler-functional-inventory.md (R-numbers referenced per test).
final class AlarmModelTests: XCTestCase {

    private func decodeAlarm(_ json: String) throws -> AlarmDefinition {
        try JSONDecoder().decode(AlarmDefinition.self, from: Data(json.utf8))
    }

    // MARK: - Legacy decode (R-14.2)

    func testLegacyFlatFieldsDecodeToTimeTrigger() throws {
        let alarm = try decodeAlarm("""
        {"id":"11111111-1111-1111-1111-111111111111","hour":7,"minute":30,"repeatDays":[2,4]}
        """)
        XCTAssertEqual(alarm.trigger, .time(hour: 7, minute: 30))
        XCTAssertEqual(alarm.recurrence, .weekly([.monday, .wednesday]))
        XCTAssertTrue(alarm.isEnabled)
        XCTAssertEqual(alarm.lifecycleState, .scheduled)
        XCTAssertEqual(alarm.snoozeCount, 0)
        XCTAssertTrue(alarm.deleteAfterUse)
    }

    func testFixedTriggerDateWinsOverFlatHourMinute() throws {
        let alarm = try decodeAlarm("""
        {"id":"11111111-1111-1111-1111-111111111111","hour":7,"minute":30,
         "fixedTriggerDate":1000000}
        """)
        guard case .fixed(let date) = alarm.trigger else {
            return XCTFail("expected fixed trigger, got \(alarm.trigger)")
        }
        XCTAssertEqual(date.timeIntervalSinceReferenceDate, 1_000_000)
    }

    func testLegacySkipNextUntilDateForcesEnabled() throws {
        let alarm = try decodeAlarm("""
        {"id":"11111111-1111-1111-1111-111111111111","hour":7,"minute":0,
         "isEnabled":false,"skipNextUntilDate":1000000}
        """)
        XCTAssertTrue(alarm.isEnabled, "legacy skip state must clear to enabled (R-14.2)")
        XCTAssertNil(alarm.activeOverride)
    }

    func testLegacyWakeCheckFieldsFoldIntoCustomSettings() throws {
        let alarm = try decodeAlarm("""
        {"id":"11111111-1111-1111-1111-111111111111","hour":7,"minute":0,
         "useDefaultSharedSettings":false,
         "wakeUpCheckEnabled":true,"wakeUpCheckDelayMinutes":90}
        """)
        guard case .custom(let settings) = alarm.settingsMode else {
            return XCTFail("expected custom settings mode")
        }
        XCTAssertTrue(settings.wakeUpCheckEnabled)
        XCTAssertEqual(settings.wakeUpCheckDelayMinutes, 60, "legacy delay is clamped on fold-in")
    }

    func testNapWithoutDurationDecodesToZeroMinutes() throws {
        let alarm = try decodeAlarm("""
        {"id":"11111111-1111-1111-1111-111111111111","hour":7,"minute":0,"alarmType":"nap"}
        """)
        XCTAssertTrue(alarm.isNap)
        XCTAssertEqual(alarm.durationMinutes, 0)
        XCTAssertNil(alarm.pausedRemainingSeconds)
    }

    // MARK: - Round trip (R-14.3)

    func testFullyPopulatedAlarmRoundTrips() throws {
        var alarm = AlarmDefinition(
            name: "Workday",
            trigger: .time(hour: 6, minute: 45),
            recurrence: .weekly([.friday, .monday]),
            type: .regular,
            deleteAfterUse: false,
            settingsMode: .custom(SharedAlarmSettings(
                snoozeEnabled: true,
                snoozeDurationMinutes: 10,
                maxSnoozes: 2,
                wakeUpCheckEnabled: true,
                wakeUpCheckDelayMinutes: 15,
                wakeUpCheckResponseTimeoutMinutes: 5,
                tasks: [.math(difficulty: .hard, count: 3), .dummy]
            )),
            nextTriggerOverrideDate: Date(timeIntervalSinceReferenceDate: 2_000_000),
            isEnabled: true,
            activeOverride: OverrideState(
                kind: .modifyNext,
                bridgeAlarmIDs: [UUID(), UUID()],
                restoreAnchorDate: Date(timeIntervalSinceReferenceDate: 3_000_000)
            ),
            snoozeCount: 1,
            lifecycleState: .awaitingWakeCheck
        )
        alarm.updatedAt = Date(timeIntervalSinceReferenceDate: 4_000_000)

        let data = try JSONEncoder().encode(alarm)
        let decoded = try JSONDecoder().decode(AlarmDefinition.self, from: data)
        XCTAssertEqual(decoded, alarm)
    }

    func testNapRoundTripsWithPauseState() throws {
        var alarm = AlarmDefinition(
            trigger: .fixed(Date(timeIntervalSinceReferenceDate: 5_000_000)),
            type: .nap(NapConfig(durationMinutes: 25, pausedRemainingSeconds: 90))
        )
        AlarmTypePolicy.normalizeOnWrite(&alarm)

        let decoded = try JSONDecoder().decode(
            AlarmDefinition.self,
            from: try JSONEncoder().encode(alarm)
        )
        XCTAssertEqual(decoded, alarm)
        XCTAssertEqual(decoded.pausedRemainingSeconds, 90)
        XCTAssertTrue(decoded.isPaused)
    }

    // MARK: - Wake-check timing clamps (R-7.3, R-11.3)

    func testCheckDelayClamping() {
        XCTAssertEqual(WakeUpCheckTimingPolicy.clampCheckDelayMinutes(0), 0, "0 is the testing sentinel")
        XCTAssertEqual(WakeUpCheckTimingPolicy.clampCheckDelayMinutes(75), 60)
        XCTAssertEqual(WakeUpCheckTimingPolicy.clampCheckDelayMinutes(-5), 1)
        XCTAssertEqual(WakeUpCheckTimingPolicy.clampCheckDelayMinutes(30), 30)
    }

    func testResponseTimeoutNormalization() {
        XCTAssertEqual(WakeUpCheckTimingPolicy.normalizeResponseTimeoutMinutes(0), 0)
        XCTAssertEqual(WakeUpCheckTimingPolicy.normalizeResponseTimeoutMinutes(-3), 1)
        XCTAssertEqual(WakeUpCheckTimingPolicy.normalizeResponseTimeoutMinutes(20), 20)
    }

    func testSentinelIntervalsResolveToFiveSeconds() {
        XCTAssertEqual(WakeUpCheckTimingPolicy.checkDelayInterval(for: 0), 5)
        XCTAssertEqual(WakeUpCheckTimingPolicy.responseTimeoutInterval(for: 0), 5)
        XCTAssertEqual(WakeUpCheckTimingPolicy.checkDelayInterval(for: 5), 300)
        XCTAssertEqual(WakeUpCheckTimingPolicy.responseTimeoutInterval(for: 3), 180)
    }

    func testSettingsClampAtInitAndDecode() throws {
        let settings = SharedAlarmSettings(
            snoozeEnabled: false, snoozeDurationMinutes: 5, maxSnoozes: nil,
            wakeUpCheckEnabled: false, wakeUpCheckDelayMinutes: 200,
            wakeUpCheckResponseTimeoutMinutes: -1
        )
        XCTAssertEqual(settings.wakeUpCheckDelayMinutes, 60)
        XCTAssertEqual(settings.wakeUpCheckResponseTimeoutMinutes, 1)

        let decoded = try JSONDecoder().decode(SharedAlarmSettings.self, from: Data("""
        {"snoozeEnabled":false,"snoozeDurationMinutes":5,
         "wakeUpCheckEnabled":false,"wakeUpCheckDelayMinutes":200,
         "wakeUpCheckResponseTimeoutMinutes":-1}
        """.utf8))
        XCTAssertEqual(decoded.wakeUpCheckDelayMinutes, 60)
        XCTAssertEqual(decoded.wakeUpCheckResponseTimeoutMinutes, 1)
        XCTAssertEqual(decoded.maxSnoozes, 3, "missing maxSnoozes falls back to featureDefaults")
    }

    // MARK: - Snooze policy (R-5.2)

    func testCanSnoozeAgainPolicy() {
        var settings = SharedAlarmSettings.featureDefaults
        settings.snoozeEnabled = false
        XCTAssertFalse(settings.canSnoozeAgain(currentCount: 0), "disabled snooze never allows")

        settings.snoozeEnabled = true
        settings.maxSnoozes = nil
        XCTAssertTrue(settings.canSnoozeAgain(currentCount: 999), "nil max = unlimited")

        settings.maxSnoozes = 3
        XCTAssertTrue(settings.canSnoozeAgain(currentCount: 2))
        XCTAssertFalse(settings.canSnoozeAgain(currentCount: 3))
    }

    // MARK: - Type policy (R-1.1)

    func testTypePolicyForcesDeleteAfterUseForNapAndTryOut() {
        var nap = AlarmDefinition(type: .nap(NapConfig(durationMinutes: 10, pausedRemainingSeconds: nil)), deleteAfterUse: false)
        AlarmTypePolicy.normalizeOnWrite(&nap)
        XCTAssertTrue(nap.deleteAfterUse)

        var tryOut = AlarmDefinition(type: .tryOut, deleteAfterUse: false)
        AlarmTypePolicy.normalizeOnWrite(&tryOut)
        XCTAssertTrue(tryOut.deleteAfterUse)

        var regular = AlarmDefinition(type: .regular, deleteAfterUse: false)
        AlarmTypePolicy.normalizeOnWrite(&regular)
        XCTAssertFalse(regular.deleteAfterUse)
    }

    // MARK: - Draft invariants (R-1.3)

    func testToggleRepeatDayClearsDeleteAfterUse() {
        var draft = AlarmDraft(deleteAfterUse: true)
        draft.toggleRepeatDay(.tuesday)
        XCTAssertEqual(draft.repeatDays, [.tuesday])
        XCTAssertFalse(draft.deleteAfterUse)

        draft.toggleRepeatDay(.tuesday)
        XCTAssertTrue(draft.repeatDays.isEmpty)
    }

    func testSetDeleteAfterUseClearsRepeatDays() {
        var draft = AlarmDraft(repeatDays: [.monday, .friday], deleteAfterUse: false)
        draft.setDeleteAfterUse(true)
        XCTAssertTrue(draft.deleteAfterUse)
        XCTAssertTrue(draft.repeatDays.isEmpty)
    }

    func testDraftToUserAlarmMapsTimeAndRecurrence() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 8
        components.hour = 6
        components.minute = 15
        let time = Calendar.autoupdatingCurrent.date(from: components)!
        let createdAt = Date(timeIntervalSinceReferenceDate: 1_000)

        let draft = AlarmDraft(name: "  Gym  ", time: time, repeatDays: [.saturday], deleteAfterUse: false)
        let alarm = draft.toUserAlarm(existingCreatedAt: createdAt, defaultSharedSettings: .featureDefaults)

        XCTAssertEqual(alarm.trigger, .time(hour: 6, minute: 15))
        XCTAssertEqual(alarm.recurrence, .weekly([.saturday]))
        XCTAssertEqual(alarm.createdAt, createdAt)
        XCTAssertEqual(alarm.name, "Gym", "name is trimmed at init (R-1.5)")
        XCTAssertTrue(alarm.isEnabled)
        XCTAssertEqual(alarm.lifecycleState, .scheduled)
    }

    // MARK: - Settings cascade (R-11.1)

    func testResolvedSharedSettingsCascade() {
        let defaults = SharedAlarmSettings.featureDefaults
        var custom = defaults
        custom.snoozeDurationMinutes = 42

        let usingDefaults = AlarmDefinition(settingsMode: .useDefault)
        XCTAssertEqual(usingDefaults.resolvedSharedSettings(defaults: defaults), defaults)

        let usingCustom = AlarmDefinition(settingsMode: .custom(custom))
        XCTAssertEqual(usingCustom.resolvedSharedSettings(defaults: defaults).snoozeDurationMinutes, 42)
    }

    // MARK: - Misc model behavior

    func testInitSortsRecurrenceDays() {
        let alarm = AlarmDefinition(recurrence: .weekly([.friday, .monday, .wednesday]))
        XCTAssertEqual(alarm.repeatDays, [.monday, .wednesday, .friday])
    }

    func testRemainingSecondsPrefersPauseAndClampsAtZero() {
        let reference = Date(timeIntervalSinceReferenceDate: 10_000)

        var nap = AlarmDefinition(
            trigger: .fixed(reference.addingTimeInterval(120)),
            type: .nap(NapConfig(durationMinutes: 2, pausedRemainingSeconds: nil))
        )
        XCTAssertEqual(nap.remainingSeconds(referenceDate: reference), 120)

        nap.pausedRemainingSeconds = 45
        XCTAssertEqual(nap.remainingSeconds(referenceDate: reference), 45, "pause wins over target date")

        let expired = AlarmDefinition(
            trigger: .fixed(reference.addingTimeInterval(-30)),
            type: .nap(NapConfig(durationMinutes: 1, pausedRemainingSeconds: nil))
        )
        XCTAssertEqual(expired.remainingSeconds(referenceDate: reference), 0)

        let timeTriggered = AlarmDefinition(trigger: .time(hour: 7, minute: 0))
        XCTAssertEqual(timeTriggered.remainingSeconds(referenceDate: reference), 0)
    }

    func testFixedTriggerDateSetterIgnoresNil() {
        // Documents D-11: clearing a fixed trigger is a silent no-op.
        var alarm = AlarmDefinition(trigger: .fixed(Date(timeIntervalSinceReferenceDate: 1_000)))
        alarm.fixedTriggerDate = nil
        XCTAssertEqual(alarm.fixedTriggerDate, Date(timeIntervalSinceReferenceDate: 1_000))
    }

    func testOverrideStateFlags() {
        var alarm = AlarmDefinition(recurrence: .weekly([.monday]), deleteAfterUse: false)
        XCTAssertFalse(alarm.isOverrideActive)
        XCTAssertFalse(alarm.isSkippingNext)
        XCTAssertFalse(alarm.isFullyDisabled)

        alarm.isEnabled = false
        XCTAssertTrue(alarm.isFullyDisabled)

        alarm.activeOverride = OverrideState(kind: .skipNext, bridgeAlarmIDs: [UUID()], restoreAnchorDate: .now)
        XCTAssertTrue(alarm.isSkippingNext)
        XCTAssertFalse(alarm.isFullyDisabled)

        alarm.isEnabled = true
        XCTAssertFalse(alarm.isSkippingNext, "skip state requires disabled + skipNext override")
    }
}
