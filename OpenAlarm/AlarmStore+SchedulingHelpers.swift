import AlarmKit
import Foundation

// MARK: - Scheduling helpers: date computation, configuration, override state

extension AlarmStore {

    // MARK: - Permission

    func ensureAuthorizedForScheduling() async throws {
        let status = await requestPermissionIfNeeded()
        guard status == .authorized else {
            throw AlarmStoreError.permissionDenied
        }
    }

    // MARK: - Configuration factory

    func makeConfiguration(
        for alarm: UserAlarm,
        schedule: Alarm.Schedule,
        forceDisableSnooze: Bool = false,
        runtimeAlarmID: UUID? = nil,
        configReferenceID: UUID? = nil
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        scheduleCoordinator.makeConfiguration(
            for: alarm,
            schedule: schedule,
            forceDisableSnooze: forceDisableSnooze,
            runtimeAlarmID: runtimeAlarmID,
            configReferenceID: configReferenceID
        )
    }

    // MARK: - Occurrence date computation

    func nextOccurrenceDate(
        in weekdays: [AlarmWeekday],
        hour: Int,
        minute: Int,
        after referenceDate: Date
    ) -> Date? {
        let calendar = Calendar.autoupdatingCurrent
        let searchStart = referenceDate.addingTimeInterval(1)

        let candidates = weekdays.compactMap { weekday -> Date? in
            var components = DateComponents()
            components.weekday = weekday.rawValue
            components.hour = hour
            components.minute = minute
            components.second = 0

            return calendar.nextDate(
                after: searchStart,
                matching: components,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            )
        }

        return candidates.min()
    }

    func nextOverrideOccurrenceDate(
        for alarm: UserAlarm,
        overrideHour: Int,
        overrideMinute: Int,
        after referenceDate: Date
    ) -> Date? {
        let calendar = Calendar.autoupdatingCurrent

        guard let baselineNext = nextOccurrenceDate(
            in: alarm.sortedRepeatDays,
            hour: alarm.hour,
            minute: alarm.minute,
            after: referenceDate
        ) else {
            return nil
        }

        var dayComponents = calendar.dateComponents([.year, .month, .day], from: baselineNext)
        dayComponents.hour = overrideHour
        dayComponents.minute = overrideMinute
        dayComponents.second = 0

        guard let candidateOnBaselineDay = calendar.date(from: dayComponents) else {
            return nil
        }

        if candidateOnBaselineDay > referenceDate {
            return candidateOnBaselineDay
        }

        return nextOccurrenceDate(
            in: alarm.sortedRepeatDays,
            hour: overrideHour,
            minute: overrideMinute,
            after: baselineNext
        )
    }

    func nextPlannedTriggerDate(for alarm: UserAlarm, after referenceDate: Date) -> Date? {
        if let overrideDate = alarm.nextTriggerOverrideDate, overrideDate > referenceDate {
            return overrideDate
        }

        if alarm.isRepeating {
            return nextOccurrenceDate(
                in: alarm.sortedRepeatDays,
                hour: alarm.hour,
                minute: alarm.minute,
                after: referenceDate
            )
        }

        let calendar = Calendar.autoupdatingCurrent
        var components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        components.hour = alarm.hour
        components.minute = alarm.minute
        components.second = 0

        guard let todayCandidate = calendar.date(from: components) else {
            return nil
        }

        if todayCandidate > referenceDate {
            return todayCandidate
        }

        return calendar.date(byAdding: .day, value: 1, to: todayCandidate)
    }

    // MARK: - Temporary schedule override

    func applyTemporaryScheduleOverrideActivation(
        _ activation: AlarmTemporaryOverrideActivationPlan,
        to alarm: inout UserAlarm,
        isEnabled: Bool,
        nextTriggerOverrideDate: Date?,
        skipNextUntilDate: Date?,
        updatedAt: Date
    ) {
        alarm.isEnabled = isEnabled
        alarm.nextTriggerOverrideDate = nextTriggerOverrideDate
        alarm.skipNextUntilDate = skipNextUntilDate
        alarm.temporaryScheduleOverride = activation.overrideState
        alarm.manualScheduleQueue = buildManualQueueEntries(
            triggerDates: activation.manualTriggerDates,
            restoreAnchorDate: activation.overrideState.restoreAnchorDate,
            configReferenceID: alarm.scheduleConfigReferenceID,
            overrideDate: activation.overrideState.overrideDate
        )
        alarm.updatedAt = updatedAt
    }

    func consumeTemporaryModifyOverrideDate(
        on alarm: inout UserAlarm,
        updatedAt: Date
    ) -> Bool {
        guard var overrideState = alarm.temporaryScheduleOverride,
              overrideState.kind == .modifyNext else {
            return false
        }

        var changed = false

        if alarm.nextTriggerOverrideDate != nil {
            alarm.nextTriggerOverrideDate = nil
            changed = true
        }

        if overrideState.overrideDate != nil {
            overrideState.overrideDate = nil
            alarm.temporaryScheduleOverride = overrideState
            changed = true
        }

        if changed {
            alarm.updatedAt = updatedAt
        }

        return changed
    }

    // MARK: - Manual queue construction

    func buildManualQueueEntries(
        triggerDates: [Date],
        restoreAnchorDate: Date,
        configReferenceID: UUID,
        overrideDate: Date?
    ) -> [AlarmManualScheduleEntry] {
        triggerDates
            .sorted()
            .map { triggerDate in
                AlarmManualScheduleEntry(
                    id: UUID(),
                    triggerDate: triggerDate,
                    restoreAnchorDate: restoreAnchorDate,
                    configReferenceID: configReferenceID,
                    role: (overrideDate != nil && triggerDate == overrideDate) ? .overrideTrigger : .canonicalBridge
                )
            }
    }

    // MARK: - Schedule mode mapping

    func desiredScheduleMode(for alarm: UserAlarm) -> AlarmScheduleDesiredMode {
        if !alarm.isEnabled,
           let skipUntil = alarm.skipNextUntilDate {
            return .temporarySkip(until: skipUntil)
        }

        if let overrideDate = alarm.nextTriggerOverrideDate {
            return .temporaryOneShot(triggerDate: overrideDate)
        }

        return alarm.isEnabled ? .recurring : .disabled
    }

    func scheduleRemoteState(for state: Alarm.State?) -> AlarmScheduleRemoteState {
        guard let state else {
            return .missing
        }

        switch state {
        case .scheduled:
            return .scheduled
        case .countdown:
            return .countdown
        case .paused:
            return .paused
        case .alerting:
            return .alerting
        @unknown default:
            return .missing
        }
    }

    // MARK: - Snooze state check

    func isSnoozeTransitionState(_ state: Alarm.State?) -> Bool {
        state == .scheduled || state == .countdown || state == .paused
    }

    // MARK: - Cancel runtime alarms

    func cancelRuntimeAlarms(ids: Set<UUID>) async {
        await scheduleCoordinator.cancelRuntimeAlarms(ids: ids)
    }

    // MARK: - Reschedule helpers

    func rescheduleAlarmsUsingDefaultSharedSettings() async {
        for alarm in alarms where alarm.useDefaultSharedSettings {
            await AlarmScheduleReconcileEntrypoint.reconcileSchedule(alarmID: alarm.id, forceRearm: true)
        }
    }
}
