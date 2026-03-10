import Foundation

// MARK: - Scheduling Phase

enum AlarmSchedulingPhase: Equatable, Sendable {
    case idle
    case scheduled(alarmKitIDs: Set<UUID>)
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
    case alarmKitStateChanged(alarmKitID: UUID, newState: AlarmKitRuntimeState)
    case stopped(alarmKitID: UUID)
    case snoozed(alarmKitID: UUID)
    case challengeCompleted(alarmKitID: UUID)
    case wakeCheckStarted
    case wakeCheckConfirmed
    case updated
}

enum AlarmKitRuntimeState: Equatable, Sendable {
    case scheduled
    case countdown
    case alerting
    case paused
    case missing
}

// MARK: - Side Effects

enum SchedulingSideEffect: Equatable, Sendable {
    case scheduleAlarmKit(alarmID: UUID, trigger: AlarmTrigger, recurrence: AlarmRecurrence)
    case cancelAlarmKit(ids: Set<UUID>)
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
        resolvedSettings: SharedAlarmSettings = .featureDefaults
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

        case (.idle, .enabled):
            return TransitionResult(
                phase: .scheduled(alarmKitIDs: [alarm.id]),
                effects: [.scheduleAlarmKit(alarmID: alarm.id, trigger: alarm.trigger, recurrence: alarm.recurrence)]
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
            effects.append(.scheduleAlarmKit(alarmID: alarm.id, trigger: alarm.trigger, recurrence: alarm.recurrence))
            return TransitionResult(phase: .scheduled(alarmKitIDs: [alarm.id]), effects: effects)

        // MARK: - AlarmKit state changes

        case (.scheduled(let ids), .alarmKitStateChanged(let akID, .alerting)) where ids.contains(akID):
            return TransitionResult(phase: .alerting(alarmKitID: akID), effects: [])

        case (.snoozed(let akID), .alarmKitStateChanged(let changedID, .alerting)) where akID == changedID:
            return TransitionResult(phase: .alerting(alarmKitID: akID), effects: [])

        // MARK: - Snooze

        case (.alerting(let akID), .snoozed(let snoozedID)) where akID == snoozedID:
            return TransitionResult(
                phase: .snoozed(alarmKitID: akID),
                effects: [.scheduleAlarmKit(alarmID: alarm.id, trigger: alarm.trigger, recurrence: alarm.recurrence)]
            )

        // MARK: - Stop

        case (.alerting(let akID), .stopped(let stoppedID)) where akID == stoppedID:
            return TransitionResult(
                phase: .awaitingDisarmChallenge(alarmKitID: akID),
                effects: []
            )

        // MARK: - Challenge completed → post-stop logic

        case (.awaitingDisarmChallenge(let akID), .challengeCompleted(let completedID)) where akID == completedID:
            if resolvedSettings.wakeUpCheckEnabled {
                return TransitionResult(
                    phase: .awaitingWakeCheck,
                    effects: [.cancelAlarmKit(ids: [akID])]
                )
            }

            if alarm.isRepeating {
                return TransitionResult(
                    phase: .scheduled(alarmKitIDs: [alarm.id]),
                    effects: [.scheduleAlarmKit(alarmID: alarm.id, trigger: alarm.trigger, recurrence: alarm.recurrence)]
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
                effects: [.cancelAlarmKit(ids: [akID])]
            )

        // MARK: - Awaiting disarm challenge: force-close alarm re-fired
        case (.awaitingDisarmChallenge(let akID), .stopped):
            return TransitionResult(phase: .awaitingDisarmChallenge(alarmKitID: akID), effects: [])

        // MARK: - Awaiting wake check: backup alarm fired (stop → stays in wake-check)

        case (.awaitingWakeCheck, .stopped):
            return TransitionResult(phase: .awaitingWakeCheck, effects: [])

        // MARK: - Wake-check confirmed

        case (.awaitingWakeCheck, .wakeCheckConfirmed):
            if alarm.isRepeating {
                return TransitionResult(
                    phase: .scheduled(alarmKitIDs: [alarm.id]),
                    effects: [.scheduleAlarmKit(alarmID: alarm.id, trigger: alarm.trigger, recurrence: alarm.recurrence)]
                )
            }

            if alarm.deleteAfterUse || alarm.isNap || alarm.isTryOut {
                return TransitionResult(
                    phase: .completed,
                    effects: [.deleteAlarm(alarm.id)]
                )
            }

            return TransitionResult(phase: .completed, effects: [])

        // MARK: - Default: no transition

        default:
            return TransitionResult(phase: current, effects: [])
        }
    }

    // MARK: - Helpers

    private static func alarmKitIDs(in phase: AlarmSchedulingPhase) -> Set<UUID> {
        switch phase {
        case .idle, .completed, .awaitingWakeCheck: return []
        case .scheduled(let ids): return ids
        case .alerting(let id): return [id]
        case .snoozed(let id): return [id]
        case .awaitingDisarmChallenge(let id): return [id]
        }
    }
}
