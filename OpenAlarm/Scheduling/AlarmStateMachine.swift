import Foundation

// MARK: - Scheduling Phase

/// In-memory scheduling phase of one alarm.
///
/// `.alerting` and `.snoozed` are entered ONLY via `AlarmStore.rebuildRuntimePhases`
/// (reconstruction from AlarmKit runtime state): stop and snooze happen in
/// extension processes (`StopIntent`/`SnoozeIntent`) that cannot dispatch events
/// into this machine. Every app-side transition goes through `transition`.
enum AlarmSchedulingPhase: Equatable, Sendable {
    case idle
    case scheduled(alarmKitIDs: Set<UUID>)
    case overrideActive(bridgeAlarmIDs: Set<UUID>)
    case alerting(alarmKitID: UUID)
    case snoozed(alarmKitID: UUID)
    case awaitingDisarmChallenge(alarmKitID: UUID)
    case awaitingWakeCheck
    case completed
}

// MARK: - Events

enum AlarmEvent: Equatable, Sendable {
    case enabled
    case disabled
    case deleted
    case updated
    /// A stop reached the app (via StopIntent's pending-disarm queue); the
    /// disarm challenge is being presented. `alarmKitID` may be a bridge UUID.
    case disarmRequested(alarmKitID: UUID)
    case challengeCompleted(alarmKitID: UUID)
    case wakeCheckConfirmed
    /// Bridge alarms were computed and are about to be scheduled by the store.
    case overrideActivated(bridgeAlarmIDs: Set<UUID>)
    /// The override lifecycle finished (anchor passed or user un-skipped);
    /// carries the bridge IDs from the alarm model so a stale phase cannot
    /// leak bridge alarms.
    case overrideRestored(bridgeAlarmIDs: Set<UUID>)
}

// MARK: - Side Effects

enum SchedulingSideEffect: Equatable, Sendable {
    /// Schedule the alarm's canonical AlarmKit registration (the store derives
    /// trigger/recurrence from the persisted alarm).
    case scheduleAlarmKit(alarmID: UUID)
    case cancelAlarmKit(ids: Set<UUID>)
    /// Replace the alarm in the store and save. Ordered BEFORE any
    /// `.scheduleAlarmKit` that depends on the updated fields (e.g. a reset
    /// snooze count must be visible when the configuration is built).
    case persist(AlarmDefinition)
    case deleteAlarm(UUID)
}

// MARK: - State Machine

enum AlarmStateMachine {
    struct TransitionResult: Equatable, Sendable {
        var phase: AlarmSchedulingPhase
        var effects: [SchedulingSideEffect]
    }

    static func transition(
        current: AlarmSchedulingPhase,
        event: AlarmEvent,
        alarm: AlarmDefinition,
        resolvedSettings: SharedAlarmSettings = .featureDefaults,
        now: Date = .now
    ) -> TransitionResult {
        switch (current, event) {

        // MARK: - Delete (from any state)

        case (_, .deleted):
            let idsToCancel = alarmKitIDs(in: current)
            var effects: [SchedulingSideEffect] = []
            if !idsToCancel.isEmpty {
                effects.append(.cancelAlarmKit(ids: idsToCancel))
            }
            effects.append(.deleteAlarm(alarm.id))
            return TransitionResult(phase: .idle, effects: effects)

        // MARK: - Disable (from any state)

        case (_, .disabled):
            let idsToCancel = alarmKitIDs(in: current)
            var effects: [SchedulingSideEffect] = []
            if !idsToCancel.isEmpty {
                effects.append(.cancelAlarmKit(ids: idsToCancel))
            }
            return TransitionResult(phase: .idle, effects: effects)

        // MARK: - Enable
        // `.completed` arm: re-enabling a finished kept one-shot must schedule
        // it again (D-13 — previously fell through to the no-op default).

        case (.idle, .enabled), (.completed, .enabled):
            return TransitionResult(
                phase: .scheduled(alarmKitIDs: [alarm.id]),
                effects: [.scheduleAlarmKit(alarmID: alarm.id)]
            )

        // MARK: - Updated (alarm was edited)

        case (_, .updated):
            if !alarm.isEnabled {
                let idsToCancel = alarmKitIDs(in: current)
                var effects: [SchedulingSideEffect] = []
                if !idsToCancel.isEmpty {
                    effects.append(.cancelAlarmKit(ids: idsToCancel))
                }
                return TransitionResult(phase: .idle, effects: effects)
            }
            let idsToCancel = alarmKitIDs(in: current)
            var effects: [SchedulingSideEffect] = []
            if !idsToCancel.isEmpty {
                effects.append(.cancelAlarmKit(ids: idsToCancel))
            }
            effects.append(.scheduleAlarmKit(alarmID: alarm.id))
            return TransitionResult(phase: .scheduled(alarmKitIDs: [alarm.id]), effects: effects)

        // MARK: - Disarm requested (from any state)
        // The alarm fired and was stopped in the intent process; the app is
        // presenting the challenge. Any phase is possible here: the fire may
        // have happened while the app was dead (phase rebuilt as .scheduled or
        // .overrideActive), mid-wake-check (backup alarm), or during a stale
        // .idle after an AlarmKit read failure.

        case (_, .disarmRequested(let akID)):
            return TransitionResult(
                phase: .awaitingDisarmChallenge(alarmKitID: akID),
                effects: []
            )

        // MARK: - Challenge completed → post-stop logic

        case (.awaitingDisarmChallenge(let akID), .challengeCompleted(let completedID)) where akID == completedID:
            return completeDisarmChallenge(
                alarmKitID: akID,
                alarm: alarm,
                resolvedSettings: resolvedSettings,
                now: now
            )

        // The app only emits challengeCompleted after the dismiss/task UI succeeds.
        // If the transient runtime phase was lost before completion, treat the UI
        // completion as the durable proof that disarm was in progress.
        case (.idle, .challengeCompleted(let completedID)):
            return completeDisarmChallenge(
                alarmKitID: completedID,
                alarm: alarm,
                resolvedSettings: resolvedSettings,
                now: now
            )

        // MARK: - Wake-check confirmed
        // Branch priority (R-7.7): override > repeating > delete-on-use > kept.

        case (.awaitingWakeCheck, .wakeCheckConfirmed):
            if let override = alarm.activeOverride {
                return TransitionResult(
                    phase: .overrideActive(bridgeAlarmIDs: Set(override.bridgeAlarmIDs)),
                    effects: [.persist(bookkept(alarm, now: now, lifecycleState: .scheduled))]
                )
            }

            if alarm.isRepeating {
                return TransitionResult(
                    phase: .scheduled(alarmKitIDs: [alarm.id]),
                    effects: [
                        .persist(bookkept(alarm, now: now, lifecycleState: .scheduled)),
                        .scheduleAlarmKit(alarmID: alarm.id),
                    ]
                )
            }

            if alarm.deleteAfterUse || alarm.isNap || alarm.isTryOut {
                return TransitionResult(
                    phase: .completed,
                    effects: [.deleteAlarm(alarm.id)]
                )
            }

            return TransitionResult(
                phase: .completed,
                effects: [.persist(bookkept(alarm, now: now, isEnabled: false, lifecycleState: .completed))]
            )

        // MARK: - Override activated (from any state)
        // The canonical registration AND whatever the current phase holds must
        // be cancelled: activating skip-next on a snoozed alarm has to kill the
        // pending snoozed instance, and a stale .idle (after an AlarmKit read
        // failure) must still cancel the canonical registration.

        case (_, .overrideActivated(let bridgeIDs)):
            let idsToCancel = alarmKitIDs(in: current).union([alarm.id])
            return TransitionResult(
                phase: .overrideActive(bridgeAlarmIDs: bridgeIDs),
                effects: [.cancelAlarmKit(ids: idsToCancel)]
            )

        // MARK: - Override restored (from any state)
        // Carries the bridge IDs from the alarm model, so bridge alarms are
        // cancelled even when the in-memory phase is stale.

        case (_, .overrideRestored(let bridgeIDs)):
            var effects: [SchedulingSideEffect] = []
            if !bridgeIDs.isEmpty {
                effects.append(.cancelAlarmKit(ids: bridgeIDs))
            }
            effects.append(.scheduleAlarmKit(alarmID: alarm.id))
            return TransitionResult(phase: .scheduled(alarmKitIDs: [alarm.id]), effects: effects)

        // MARK: - Default: no transition

        default:
            return TransitionResult(phase: current, effects: [])
        }
    }

    // MARK: - Helpers

    /// Post-disarm branch logic. Priority is behavior-critical (R-4.3):
    /// wake-check > override-bridge > repeating > deleteAfterUse > kept.
    private static func completeDisarmChallenge(
        alarmKitID akID: UUID,
        alarm: AlarmDefinition,
        resolvedSettings: SharedAlarmSettings,
        now: Date
    ) -> TransitionResult {
        if resolvedSettings.wakeUpCheckEnabled {
            return TransitionResult(
                phase: .awaitingWakeCheck,
                effects: [
                    .cancelAlarmKit(ids: [akID]),
                    .persist(bookkept(alarm, now: now, lifecycleState: .awaitingWakeCheck)),
                ]
            )
        }

        if let override = alarm.activeOverride, override.bridgeAlarmIDs.contains(akID) {
            let remainingBridgeIDs = Set(override.bridgeAlarmIDs).subtracting([akID])
            return TransitionResult(
                phase: .overrideActive(bridgeAlarmIDs: remainingBridgeIDs),
                effects: [
                    .cancelAlarmKit(ids: [akID]),
                    .persist(bookkept(alarm, now: now, lifecycleState: .scheduled)),
                ]
            )
        }

        if alarm.isRepeating {
            return TransitionResult(
                phase: .scheduled(alarmKitIDs: [alarm.id]),
                effects: [
                    .persist(bookkept(alarm, now: now, lifecycleState: .scheduled)),
                    .scheduleAlarmKit(alarmID: alarm.id),
                ]
            )
        }

        if alarm.deleteAfterUse {
            return TransitionResult(
                phase: .completed,
                effects: [.cancelAlarmKit(ids: [akID]), .deleteAlarm(alarm.id)]
            )
        }

        return TransitionResult(
            phase: .completed,
            effects: [
                .cancelAlarmKit(ids: [akID]),
                .persist(bookkept(alarm, now: now, isEnabled: false, lifecycleState: .completed)),
            ]
        )
    }

    /// Post-lifecycle bookkeeping applied to the persisted alarm. Snooze count
    /// always resets when a lifecycle completes (R-5.5).
    private static func bookkept(
        _ alarm: AlarmDefinition,
        now: Date,
        isEnabled: Bool? = nil,
        lifecycleState: AlarmLifecycleState
    ) -> AlarmDefinition {
        var updated = alarm
        updated.snoozeCount = 0
        if let isEnabled {
            updated.isEnabled = isEnabled
        }
        updated.lifecycleState = lifecycleState
        updated.updatedAt = now
        return updated
    }

    private static func alarmKitIDs(in phase: AlarmSchedulingPhase) -> Set<UUID> {
        switch phase {
        case .idle, .completed, .awaitingWakeCheck: return []
        case .scheduled(let ids): return ids
        case .overrideActive(let ids): return ids
        case .alerting(let id): return [id]
        case .snoozed(let id): return [id]
        case .awaitingDisarmChallenge(let id): return [id]
        }
    }
}

// MARK: - Alarm List Display Policy

enum AlarmListDisplayPolicy {
    enum Presentation: Equatable, Sendable {
        case show(alarm: AlarmDefinition, isInteractive: Bool)
        case hide
    }

    static func presentation(
        for alarm: AlarmDefinition,
        hasActiveWakeCheckSession: Bool
    ) -> Presentation {
        guard hasActiveWakeCheckSession, !alarm.isRepeating else {
            return .show(alarm: alarm, isInteractive: true)
        }

        if alarm.deleteAfterUse || alarm.isNap || alarm.isTryOut {
            return .hide
        }

        var projectedAlarm = alarm
        projectedAlarm.isEnabled = false
        projectedAlarm.snoozeCount = 0
        projectedAlarm.lifecycleState = .completed
        return .show(alarm: projectedAlarm, isInteractive: false)
    }
}
