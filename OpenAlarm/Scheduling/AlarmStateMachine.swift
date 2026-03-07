import Foundation

// MARK: - Scheduling Phase

enum AlarmSchedulingPhase: Equatable, Sendable {
    case idle
    case scheduled(alarmKitIDs: Set<UUID>)
    case alerting(alarmKitID: UUID)
    case completed
}

// MARK: - Events

enum AlarmEvent: Equatable, Sendable {
    case enabled
    case disabled
    case deleted
    case alarmKitStateChanged(alarmKitID: UUID, newState: AlarmKitRuntimeState)
    case stopped(alarmKitID: UUID)
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
        settings: AlarmSettings
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

        // MARK: - AlarmKit state changes

        case (.scheduled(let ids), .alarmKitStateChanged(let akID, .alerting)) where ids.contains(akID):
            return TransitionResult(phase: .alerting(alarmKitID: akID), effects: [])

        // MARK: - Stop

        case (.alerting(let akID), .stopped(let stoppedID)) where akID == stoppedID:
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

        // MARK: - Default: no transition

        default:
            return TransitionResult(phase: current, effects: [])
        }
    }

    // MARK: - Helpers

    private static func alarmKitIDs(in phase: AlarmSchedulingPhase) -> Set<UUID> {
        switch phase {
        case .idle, .completed: return []
        case .scheduled(let ids): return ids
        case .alerting(let id): return [id]
        }
    }
}
