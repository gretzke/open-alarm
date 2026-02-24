import AlarmKit
import AppIntents
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AlarmStore: ObservableObject {
    @Published private(set) var alarms: [UserAlarm] = []
    @Published private(set) var permissionStatus: AlarmPermissionStatus
    @Published private(set) var remoteStates: [UUID: Alarm.State] = [:]

    private let alarmManager: AlarmManager
    private let permissionService: AlarmPermissionService
    private let userDefaults: UserDefaults

    private var alarmUpdatesTask: Task<Void, Never>?
    private var lastKnownAlarmState: [UUID: Alarm.State] = [:]
    private var pendingRepeatRestores: Set<UUID> = []

    init(
        alarmManager: AlarmManager = .shared,
        permissionService: AlarmPermissionService? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.alarmManager = alarmManager
        self.permissionService = permissionService ?? AlarmPermissionService(manager: alarmManager)
        self.userDefaults = userDefaults
        self.permissionStatus = self.permissionService.currentStatus()

        load()
        observeAlarmUpdates()
        refreshFromSystem()
    }

    deinit {
        alarmUpdatesTask?.cancel()
    }

    func handleAppOpened() {
        refreshFromSystem()
    }

    func requestPermissionIfNeeded() async -> AlarmPermissionStatus {
        switch permissionService.currentStatus() {
        case .notDetermined:
            permissionStatus = await permissionService.requestAuthorization()
        case .denied:
            permissionStatus = .denied
        case .authorized:
            permissionStatus = .authorized
        }
        return permissionStatus
    }

    func openSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(settingsURL)
    }

    func createAlarm(from draft: AlarmDraft) async throws {
        try await upsertAlarm(existingAlarm: nil, draft: draft)
    }

    func updateAlarm(_ alarm: UserAlarm, with draft: AlarmDraft) async throws {
        try await upsertAlarm(existingAlarm: alarm, draft: draft)
    }

    func deleteAlarm(_ alarm: UserAlarm) {
        try? alarmManager.cancel(id: alarm.id)
        alarms.removeAll { $0.id == alarm.id }
        remoteStates.removeValue(forKey: alarm.id)
        lastKnownAlarmState.removeValue(forKey: alarm.id)
        save()
    }

    func scheduleTryOut(from draft: AlarmDraft, after seconds: TimeInterval) async throws {
        try await ensureAuthorizedForScheduling()

        let shadowID = UUID()
        let baseAlarm = draft.toUserAlarm(id: shadowID, existingCreatedAt: nil)
        let trialDate = Date.now.addingTimeInterval(seconds)

        let config = makeConfiguration(for: baseAlarm, schedule: .fixed(trialDate), isShadowTrial: true)
        _ = try await alarmManager.schedule(id: shadowID, configuration: config)

        var trials = AlarmPersistence.loadShadowTrials(from: userDefaults)
        trials.removeAll { $0.id == shadowID }
        trials.append(ShadowTrialAlarm(
            id: shadowID,
            snoozeEnabled: baseAlarm.snoozeEnabled,
            snoozeDurationMinutes: baseAlarm.snoozeDurationMinutes,
            maxSnoozes: baseAlarm.maxSnoozes,
            snoozeCount: 0,
            wakeUpCheckEnabled: baseAlarm.wakeUpCheckEnabled,
            lifecycleState: .scheduled,
            createdAt: .now,
            updatedAt: .now
        ))
        AlarmPersistence.saveShadowTrials(trials, to: userDefaults)
    }

    func lifecycleLabel(for state: AlarmLifecycleState) -> LocalizedStringKey {
        switch state {
        case .scheduled:
            return L10n.alarmStateScheduled
        case .alerting:
            return L10n.alarmStateAlerting
        case .awaitingWakeCheck:
            return L10n.alarmStateAwaitingWakeCheck
        case .completed:
            return L10n.alarmStateCompleted
        }
    }

    func permissionStatusLabel() -> LocalizedStringKey {
        switch permissionStatus {
        case .authorized:
            return L10n.settingsPermissionAuthorized
        case .notDetermined:
            return L10n.settingsPermissionNotDetermined
        case .denied:
            return L10n.settingsPermissionDenied
        }
    }

    func userFacingErrorMessage(for error: Error) -> LocalizedStringKey {
        guard let storeError = error as? AlarmStoreError else {
            return L10n.alarmEditorErrorGeneric
        }

        switch storeError {
        case .permissionDenied:
            return L10n.alarmEditorErrorPermissionDenied
        case .scheduleFailed:
            return L10n.alarmEditorErrorGeneric
        }
    }

    private func upsertAlarm(existingAlarm: UserAlarm?, draft: AlarmDraft) async throws {
        try await ensureAuthorizedForScheduling()

        let id = existingAlarm?.id ?? UUID()
        var nextAlarm = draft.toUserAlarm(id: id, existingCreatedAt: existingAlarm?.createdAt)

        do {
            let config = makeConfiguration(for: nextAlarm, schedule: nextAlarm.schedule, isShadowTrial: false)
            let remoteAlarm = try await alarmManager.schedule(id: id, configuration: config)
            nextAlarm.lifecycleState = remoteAlarm.state == .alerting ? .alerting : .scheduled
            nextAlarm.snoozeCount = 0
            lastKnownAlarmState[id] = remoteAlarm.state
            remoteStates[id] = remoteAlarm.state
        } catch {
            throw AlarmStoreError.scheduleFailed
        }

        if let existingIndex = alarms.firstIndex(where: { $0.id == id }) {
            alarms[existingIndex] = nextAlarm
        } else {
            alarms.append(nextAlarm)
        }

        alarms = sortAlarms(alarms)
        save()
    }

    private func ensureAuthorizedForScheduling() async throws {
        let status = await requestPermissionIfNeeded()
        guard status == .authorized else {
            throw AlarmStoreError.permissionDenied
        }
    }

    private func makeConfiguration(
        for alarm: UserAlarm,
        schedule: Alarm.Schedule,
        isShadowTrial: Bool
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let showSnoozeButton = alarm.canSnoozeAgain

        let alertPresentation = AlarmPresentation.Alert(
            title: LocalizedStringResource("app_title"),
            stopButton: .stopButton,
            secondaryButton: showSnoozeButton ? .snoozeButton : nil,
            secondaryButtonBehavior: showSnoozeButton ? .custom : nil
        )

        let presentation = AlarmPresentation(alert: alertPresentation)

        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: OpenAlarmMetadata(source: alarm.id.uuidString, isShadowTrial: isShadowTrial),
            tintColor: OAColor.actionCyan
        )

        let secondaryIntent: (any LiveActivityIntent)? = if showSnoozeButton {
            SnoozeIntent(alarmID: alarm.id.uuidString)
        } else {
            nil
        }

        return .init(
            countdownDuration: nil,
            schedule: schedule,
            attributes: attributes,
            stopIntent: nil,
            secondaryIntent: secondaryIntent,
            sound: .default
        )
    }

    private func observeAlarmUpdates() {
        alarmUpdatesTask = Task { [weak self] in
            guard let self else {
                return
            }

            for await incoming in alarmManager.alarmUpdates {
                if Task.isCancelled {
                    return
                }
                applyRemoteAlarms(incoming)
            }
        }
    }

    private func refreshFromSystem() {
        permissionStatus = permissionService.currentStatus()
        do {
            let remote = try alarmManager.alarms
            applyRemoteAlarms(remote)
        } catch {
            remoteStates = [:]
        }
    }

    private func applyRemoteAlarms(_ incoming: [Alarm]) {
        let remoteByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })

        var updated = alarms
        var changed = mergeSnoozeCountsFromPersistence(into: &updated)

        handleShadowTrials(remoteByID: remoteByID)

        remoteStates = Dictionary(
            uniqueKeysWithValues: updated.compactMap { alarm in
                guard let state = remoteByID[alarm.id]?.state else {
                    return nil
                }
                return (alarm.id, state)
            }
        )

        var idsToAutoDelete: Set<UUID> = []

        for index in updated.indices {
            let alarmID = updated[index].id
            let previousState = lastKnownAlarmState[alarmID]
            let currentState = remoteByID[alarmID]?.state

            if let currentState {
                lastKnownAlarmState[alarmID] = currentState
            } else {
                lastKnownAlarmState.removeValue(forKey: alarmID)
            }

            if previousState == .alerting, currentState != .alerting {
                applyPostAlertTransition(
                    alarm: &updated[index],
                    currentState: currentState,
                    idsToAutoDelete: &idsToAutoDelete,
                    changed: &changed
                )
                continue
            }

            guard let currentState else {
                continue
            }

            switch currentState {
            case .alerting:
                if updated[index].lifecycleState != .alerting {
                    updated[index].lifecycleState = .alerting
                    changed = true
                }
            case .scheduled, .countdown, .paused:
                if updated[index].lifecycleState != .scheduled {
                    updated[index].lifecycleState = .scheduled
                    changed = true
                }
            @unknown default:
                break
            }
        }

        if !idsToAutoDelete.isEmpty {
            for id in idsToAutoDelete {
                try? alarmManager.cancel(id: id)
                remoteStates.removeValue(forKey: id)
                lastKnownAlarmState.removeValue(forKey: id)
            }
            updated.removeAll { idsToAutoDelete.contains($0.id) }
            changed = true
        }

        if changed {
            alarms = sortAlarms(updated)
            save()
        }
    }

    private func applyPostAlertTransition(
        alarm: inout UserAlarm,
        currentState: Alarm.State?,
        idsToAutoDelete: inout Set<UUID>,
        changed: inout Bool
    ) {
        let hadSnoozes = alarm.snoozeCount > 0

        // Snooze was tapped and alarm got rescheduled by SnoozeIntent.
        if currentState == .scheduled, alarm.snoozeEnabled, hadSnoozes {
            if alarm.lifecycleState != .scheduled {
                alarm.lifecycleState = .scheduled
                changed = true
            }
            return
        }

        if hadSnoozes {
            alarm.snoozeCount = 0
            alarm.updatedAt = .now
            changed = true
        }

        if alarm.isRepeating {
            if hadSnoozes {
                scheduleRepeatRestore(for: alarm)
            }
            if alarm.lifecycleState != .scheduled {
                alarm.lifecycleState = .scheduled
                changed = true
            }
            return
        }

        if alarm.wakeUpCheckEnabled {
            if alarm.lifecycleState != .awaitingWakeCheck {
                alarm.lifecycleState = .awaitingWakeCheck
                changed = true
            }
            return
        }

        if alarm.lifecycleState != .completed {
            alarm.lifecycleState = .completed
            changed = true
        }

        if alarm.deleteAfterUse {
            idsToAutoDelete.insert(alarm.id)
        }
    }

    private func scheduleRepeatRestore(for alarm: UserAlarm) {
        guard !pendingRepeatRestores.contains(alarm.id) else {
            return
        }

        pendingRepeatRestores.insert(alarm.id)
        let restoredAlarm = alarm

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer { pendingRepeatRestores.remove(restoredAlarm.id) }

            do {
                let config = makeConfiguration(for: restoredAlarm, schedule: restoredAlarm.schedule, isShadowTrial: false)
                let remote = try await alarmManager.schedule(id: restoredAlarm.id, configuration: config)
                lastKnownAlarmState[restoredAlarm.id] = remote.state
                remoteStates[restoredAlarm.id] = remote.state
            } catch {
                // Best effort; future refresh can recover.
            }
        }
    }

    private func handleShadowTrials(remoteByID: [UUID: Alarm]) {
        var trials = AlarmPersistence.loadShadowTrials(from: userDefaults)
        var changed = false

        for index in trials.indices.reversed() {
            let trialID = trials[index].id
            let previousState = lastKnownAlarmState[trialID]
            let currentState = remoteByID[trialID]?.state

            if let currentState {
                lastKnownAlarmState[trialID] = currentState
            } else {
                lastKnownAlarmState.removeValue(forKey: trialID)
            }

            if previousState == .alerting, currentState != .alerting {
                if currentState == .scheduled, trials[index].snoozeEnabled, trials[index].snoozeCount > 0 {
                    if trials[index].lifecycleState != .scheduled {
                        trials[index].lifecycleState = .scheduled
                        trials[index].updatedAt = .now
                        changed = true
                    }
                    continue
                }

                if trials[index].wakeUpCheckEnabled {
                    if trials[index].lifecycleState != .awaitingWakeCheck {
                        trials[index].lifecycleState = .awaitingWakeCheck
                        trials[index].updatedAt = .now
                        changed = true
                    }
                    continue
                }

                try? alarmManager.stop(id: trialID)
                try? alarmManager.cancel(id: trialID)
                trials.remove(at: index)
                changed = true
                continue
            }

            if let currentState {
                switch currentState {
                case .alerting:
                    if trials[index].lifecycleState != .alerting {
                        trials[index].lifecycleState = .alerting
                        trials[index].updatedAt = .now
                        changed = true
                    }
                case .scheduled, .countdown, .paused:
                    if trials[index].lifecycleState != .scheduled {
                        trials[index].lifecycleState = .scheduled
                        trials[index].updatedAt = .now
                        changed = true
                    }
                @unknown default:
                    break
                }
            }

            if currentState == nil, trials[index].lifecycleState != .awaitingWakeCheck {
                trials.remove(at: index)
                changed = true
            }
        }

        if changed {
            AlarmPersistence.saveShadowTrials(trials, to: userDefaults)
        }
    }

    private func mergeSnoozeCountsFromPersistence(into alarms: inout [UserAlarm]) -> Bool {
        let persisted = Dictionary(uniqueKeysWithValues: AlarmPersistence.loadUserAlarms(from: userDefaults).map { ($0.id, $0.snoozeCount) })

        var changed = false
        for index in alarms.indices {
            guard let persistedCount = persisted[alarms[index].id] else {
                continue
            }
            if alarms[index].snoozeCount != persistedCount {
                alarms[index].snoozeCount = persistedCount
                changed = true
            }
        }
        return changed
    }

    private func sortAlarms(_ alarms: [UserAlarm]) -> [UserAlarm] {
        alarms.sorted { lhs, rhs in
            if lhs.hour == rhs.hour {
                if lhs.minute == rhs.minute {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.minute < rhs.minute
            }
            return lhs.hour < rhs.hour
        }
    }

    private func load() {
        alarms = sortAlarms(AlarmPersistence.loadUserAlarms(from: userDefaults))
    }

    private func save() {
        AlarmPersistence.saveUserAlarms(alarms, to: userDefaults)
    }
}

enum AlarmStoreError: Error {
    case permissionDenied
    case scheduleFailed
}

extension AlarmButton {
    static var snoozeButton: Self {
        AlarmButton(text: "Snooze", textColor: .black, systemImageName: "zzz")
    }

    static var stopButton: Self {
        AlarmButton(text: "Done", textColor: .white, systemImageName: "stop.circle")
    }
}
