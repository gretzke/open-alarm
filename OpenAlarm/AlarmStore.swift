import AlarmKit
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

    private let storageKey = "OPENALARM_USER_ALARMS_V1"

    private var alarmUpdatesTask: Task<Void, Never>?
    private var lastKnownAlarmState: [UUID: Alarm.State] = [:]
    private var shadowTrials: [UUID: ShadowTrialPhase] = [:]

    private enum ShadowTrialPhase {
        case armed
        case alertingSeen
    }

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
        let trialAlarm = draft.toUserAlarm(id: shadowID, existingCreatedAt: nil)
        let trialDate = Date.now.addingTimeInterval(seconds)
        let config = makeConfiguration(for: trialAlarm, schedule: .fixed(trialDate), isShadowTrial: true)

        _ = try await alarmManager.schedule(id: shadowID, configuration: config)
        shadowTrials[shadowID] = .armed
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

        let config = makeConfiguration(for: nextAlarm, schedule: nextAlarm.schedule, isShadowTrial: false)

        do {
            let remoteAlarm = try await alarmManager.schedule(id: id, configuration: config)
            if remoteAlarm.state == .alerting {
                nextAlarm.lifecycleState = .alerting
            } else {
                nextAlarm.lifecycleState = .scheduled
            }
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
        let alertPresentation = AlarmPresentation.Alert(
            title: LocalizedStringResource("app_title"),
            stopButton: .stopButton
        )

        let presentation = AlarmPresentation(alert: alertPresentation)
        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: OpenAlarmMetadata(source: alarm.id.uuidString, isShadowTrial: isShadowTrial),
            tintColor: OAColor.actionCyan
        )

        return .alarm(
            schedule: schedule,
            attributes: attributes,
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

        handleShadowTrials(remoteByID: remoteByID)

        remoteStates = Dictionary(
            uniqueKeysWithValues: alarms.compactMap { alarm in
                guard let state = remoteByID[alarm.id]?.state else {
                    return nil
                }
                return (alarm.id, state)
            }
        )

        var updated = alarms
        var idsToAutoDelete: Set<UUID> = []
        var changed = false

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
                applyPostAlertTransition(alarm: &updated[index], idsToAutoDelete: &idsToAutoDelete, changed: &changed)
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
        idsToAutoDelete: inout Set<UUID>,
        changed: inout Bool
    ) {
        if alarm.isRepeating {
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

    private func handleShadowTrials(remoteByID: [UUID: Alarm]) {
        for trialID in Array(shadowTrials.keys) {
            guard let phase = shadowTrials[trialID] else {
                continue
            }

            let currentState = remoteByID[trialID]?.state

            switch (phase, currentState) {
            case (_, nil):
                shadowTrials.removeValue(forKey: trialID)
            case (.armed, .some(.alerting)):
                shadowTrials[trialID] = .alertingSeen
            case (.alertingSeen, .some(let state)) where state != .alerting:
                try? alarmManager.stop(id: trialID)
                try? alarmManager.cancel(id: trialID)
                shadowTrials.removeValue(forKey: trialID)
            default:
                break
            }
        }
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
        guard let data = userDefaults.data(forKey: storageKey) else {
            alarms = []
            return
        }

        do {
            let decoded = try JSONDecoder().decode([UserAlarm].self, from: data)
            alarms = sortAlarms(decoded)
        } catch {
            alarms = []
        }
    }

    private func save() {
        do {
            let encoded = try JSONEncoder().encode(alarms)
            userDefaults.set(encoded, forKey: storageKey)
        } catch {
            userDefaults.removeObject(forKey: storageKey)
        }
    }
}

enum AlarmStoreError: Error {
    case permissionDenied
    case scheduleFailed
}

extension AlarmButton {
    static var stopButton: Self {
        AlarmButton(text: "Done", textColor: .white, systemImageName: "stop.circle")
    }
}
