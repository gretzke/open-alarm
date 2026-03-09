import AlarmKit
import AppIntents
import Combine
import Foundation
import os
import SwiftUI

// MARK: - AlarmStore

@MainActor
final class AlarmStore: ObservableObject {
    private static let logger = Logger(subsystem: "com.openalarm", category: "AlarmStore")

    // MARK: - Published Properties

    @Published internal var alarms: [UserAlarm] = []
    @Published var defaultSharedSettings: SharedAlarmSettings
    @Published var napDefaultSharedSettings: SharedAlarmSettings?  // nil = use global defaults
    @Published var defaultNapDurationMinutes: Int
    @Published var testingModeEnabled: Bool
    @Published var permissionStatus: AlarmPermissionStatus
    @Published var notificationPermissionStatus: NotificationPermissionStatus = .notDetermined
    @Published var remoteStates: [UUID: Alarm.State] = [:]

    // NOOP: Phase 4
    @Published var wakeUpCheckConfirmationPresentation: WakeUpCheckConfirmationPresentation?

    // MARK: - Computed Properties

    var activeNap: UserAlarm? {
        alarms.first { $0.isNap }
    }

    var regularAlarms: [UserAlarm] {
        alarms.filter { $0.alarmType == .regular }
    }

    var useGlobalDefaultsForNap: Bool {
        napDefaultSharedSettings == nil
    }

    /// Returns the effective defaults for nap alarms (nap-specific or global)
    var resolvedNapDefaults: SharedAlarmSettings {
        napDefaultSharedSettings ?? defaultSharedSettings
    }

    // MARK: - Dependencies

    private let alarmManager: AlarmManager
    private let permissionService: AlarmPermissionService
    private let notificationPermissionService: NotificationPermissionService
    private let persistence: AlarmPersistence
    private var alarmUpdatesTask: Task<Void, Never>?

    // MARK: - Init

    init(
        alarmManager: AlarmManager = .shared,
        permissionService: AlarmPermissionService? = nil,
        notificationPermissionService: NotificationPermissionService? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.alarmManager = alarmManager
        self.permissionService = permissionService ?? AlarmPermissionService(manager: alarmManager)
        self.notificationPermissionService = notificationPermissionService ?? NotificationPermissionService()
        self.persistence = AlarmPersistence(defaults: userDefaults)
        self.defaultSharedSettings = persistence.loadDefaultSharedSettings()
        self.napDefaultSharedSettings = persistence.loadNapDefaultSharedSettings()
        self.defaultNapDurationMinutes = persistence.loadDefaultNapDurationMinutes()
        self.testingModeEnabled = persistence.loadTestingModeEnabled()
        self.permissionStatus = self.permissionService.currentStatus()

        WakeUpCheckNotificationService().ensureCategoryRegistered()

        load()
        observeAlarmUpdates()
    }

    deinit {
        alarmUpdatesTask?.cancel()
    }

    // MARK: - Load

    private func load() {
        alarms = sortAlarms(persistence.loadUserAlarms())
    }

    // MARK: - App Lifecycle

    func handleAppOpened() {
        permissionStatus = permissionService.currentStatus()
        load()
        refreshRemoteState()
    }

    private func refreshRemoteState() {
        do {
            let remote = try alarmManager.alarms
            applyRemoteAlarms(remote)
        } catch {
            remoteStates = [:]
        }
    }

    // MARK: - Create Alarm (unified code path)

    func createAlarm(from draft: AlarmDraft) async throws {
        if permissionStatus != .authorized {
            let status = await requestPermissionIfNeeded()
            guard status == .authorized else {
                throw AlarmStoreError.permissionDenied
            }
        }

        let alarm = draft.toUserAlarm(
            defaultSharedSettings: defaultSharedSettings
        )

        alarms.append(alarm)
        alarms = sortAlarms(alarms)
        saveAlarms()

        await scheduleAlarm(alarm)
    }

    // MARK: - Update Alarm

    func updateAlarm(_ alarm: UserAlarm, with draft: AlarmDraft, clearNextOverride: Bool = false) async throws {
        if permissionStatus != .authorized {
            let status = await requestPermissionIfNeeded()
            guard status == .authorized else {
                throw AlarmStoreError.permissionDenied
            }
        }

        guard let index = alarms.firstIndex(where: { $0.id == alarm.id }) else { return }

        let updated = draft.toUserAlarm(
            id: alarm.id,
            existingCreatedAt: alarm.createdAt,
            defaultSharedSettings: defaultSharedSettings
        )

        // Cancel old schedule
        try? alarmManager.stop(id: alarm.id)
        try? alarmManager.cancel(id: alarm.id)

        alarms[index] = updated
        alarms = sortAlarms(alarms)
        saveAlarms()

        // Reschedule if enabled
        if updated.isEnabled {
            await scheduleAlarm(updated)
        }
    }

    // MARK: - Update Next Alarm Occurrence

    func updateNextAlarmOccurrence(_ alarm: UserAlarm, with draft: AlarmDraft) async throws {
        // NOOP: Phase 5
    }

    // MARK: - Delete Alarm

    func deleteAlarm(_ alarm: UserAlarm) {
        try? alarmManager.stop(id: alarm.id)
        try? alarmManager.cancel(id: alarm.id)

        alarms.removeAll { $0.id == alarm.id }
        remoteStates.removeValue(forKey: alarm.id)
        saveAlarms()
    }

    // MARK: - Set Alarm Enabled

    func setAlarmEnabled(_ alarm: UserAlarm, enabled: Bool, skipNext: Bool? = nil) async throws {
        if enabled {
            let status = await requestPermissionIfNeeded()
            guard status == .authorized else {
                throw AlarmStoreError.permissionDenied
            }
        }

        guard let index = alarms.firstIndex(where: { $0.id == alarm.id }) else { return }

        // skipNext is Phase 5 — for now treat as full disable
        alarms[index].isEnabled = enabled
        alarms[index].snoozeCount = 0
        alarms[index].updatedAt = .now

        if enabled {
            alarms[index].lifecycleState = .scheduled
        }

        alarms = sortAlarms(alarms)
        saveAlarms()

        if enabled {
            await scheduleAlarm(alarms.first(where: { $0.id == alarm.id })!)
        } else {
            try? alarmManager.stop(id: alarm.id)
            try? alarmManager.cancel(id: alarm.id)
        }
    }

    // MARK: - Create Nap (unified code path)

    func createNap(from draft: NapDraft) async throws {
        if permissionStatus != .authorized {
            let status = await requestPermissionIfNeeded()
            guard status == .authorized else {
                throw AlarmStoreError.permissionDenied
            }
        }

        // Remove existing nap if any
        if let existingNap = activeNap {
            deleteAlarm(existingNap)
        }

        let targetDate = Date.now.addingTimeInterval(TimeInterval(draft.totalMinutes * 60))
        let alarm = UserAlarm.makeNap(
            from: draft,
            defaultSharedSettings: resolvedNapDefaults,
            targetDate: targetDate
        )

        alarms.append(alarm)
        alarms = sortAlarms(alarms)
        saveAlarms()

        await scheduleAlarm(alarm)
    }

    // MARK: - Pause Nap

    func pauseNap() {
        guard let nap = activeNap, !nap.isPaused else { return }

        let remaining = nap.remainingSeconds()

        guard let index = alarms.firstIndex(where: { $0.id == nap.id }) else { return }
        alarms[index].pausedRemainingSeconds = remaining
        alarms[index].updatedAt = .now
        saveAlarms()

        try? alarmManager.stop(id: nap.id)
        try? alarmManager.cancel(id: nap.id)
    }

    // MARK: - Resume Nap

    func resumeNap() async {
        guard let nap = activeNap, nap.isPaused,
              let remaining = nap.pausedRemainingSeconds else { return }

        let newTarget = Date.now.addingTimeInterval(remaining)

        guard let index = alarms.firstIndex(where: { $0.id == nap.id }) else { return }
        alarms[index].fixedTriggerDate = newTarget
        alarms[index].pausedRemainingSeconds = nil
        alarms[index].updatedAt = .now
        saveAlarms()

        await scheduleAlarm(alarms[index])
    }

    // MARK: - Delete Nap

    func deleteNap() {
        guard let nap = activeNap else { return }
        deleteAlarm(nap)
    }

    // MARK: - Schedule Try-Out (unified code path)

    func scheduleTryOut(sharedSettings: SharedAlarmSettings, after seconds: TimeInterval) async throws {
        if permissionStatus != .authorized {
            let status = await requestPermissionIfNeeded()
            guard status == .authorized else {
                throw AlarmStoreError.permissionDenied
            }
        }

        // Remove existing tryOuts
        let existing = alarms.filter { $0.isTryOut }
        for alarm in existing {
            deleteAlarm(alarm)
        }

        let triggerDate = Date.now.addingTimeInterval(seconds)
        let id = UUID()
        var alarm = UserAlarm(
            id: id,
            name: "",
            hour: 0,
            minute: 0,
            repeatDays: [],
            deleteAfterUse: true,
            alarmType: .tryOut,
            fixedTriggerDate: triggerDate,
            useDefaultSharedSettings: false,
            customSharedSettings: sharedSettings,
            nextTriggerOverrideDate: nil,
            isEnabled: true,
            skipNextUntilDate: nil,
            snoozeCount: 0,
            lifecycleState: .scheduled,
            createdAt: .now,
            updatedAt: .now
        )
        AlarmTypePolicy.normalizeOnWrite(&alarm)

        alarms.append(alarm)
        alarms = sortAlarms(alarms)
        saveAlarms()

        await scheduleAlarm(alarm)
    }

    // MARK: - Settings

    func updateDefaultSharedSettings(_ settings: SharedAlarmSettings) {
        defaultSharedSettings = settings
        persistence.saveDefaultSharedSettings(settings)
    }

    func updateTestingModeEnabled(_ enabled: Bool) {
        testingModeEnabled = enabled
        persistence.saveTestingModeEnabled(enabled)
    }

    func updateNapDefaultSharedSettings(_ settings: SharedAlarmSettings?) {
        napDefaultSharedSettings = settings
        persistence.saveNapDefaultSharedSettings(settings)
    }

    func updateDefaultNapDurationMinutes(_ minutes: Int) {
        defaultNapDurationMinutes = max(1, minutes)
        persistence.saveDefaultNapDurationMinutes(defaultNapDurationMinutes)
    }

    func openSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(settingsURL)
    }

    // MARK: - Permissions

    @discardableResult
    func requestPermissionIfNeeded() async -> AlarmPermissionStatus {
        let status = await permissionService.requestAuthorization()
        permissionStatus = status
        return status
    }

    @discardableResult
    func refreshNotificationPermissionStatus() async -> NotificationPermissionStatus {
        let status = await notificationPermissionService.currentStatus()
        notificationPermissionStatus = status
        return status
    }

    func requestNotificationPermissionIfNeeded() async -> NotificationPermissionStatus {
        let status = await notificationPermissionService.requestAuthorization()
        notificationPermissionStatus = status
        return status
    }

    // MARK: - Wake-Up Check (Phase 6 no-ops)

    func disableWakeUpCheckFeatureGlobally() {
        // NOOP: Phase 4
    }

    func confirmWakeUpCheck(for alarmID: UUID) async {
        // NOOP: Phase 4
    }

    func applyWakeUpCheckGracePeriodIfNeeded(for alarmID: UUID) async -> Date? {
        // NOOP: Phase 4
        return nil
    }

    func shouldPresentWakeCheckPermissionDeniedPromptOnLaunch() async -> Bool {
        // NOOP: Phase 4
        return false
    }

    // MARK: - Error Display

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

    // MARK: - View Helpers

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

    // MARK: - Internal Scheduling (unified code path)

    private func scheduleAlarm(_ alarm: UserAlarm) async {
        let runtimeSchedule = AlarmScheduleResolver.runtimeSchedule(for: alarm)
        let config = makeConfiguration(for: alarm, schedule: runtimeSchedule)

        do {
            _ = try await alarmManager.schedule(id: alarm.id, configuration: config)
        } catch {
            Self.logger.warning("Schedule failed for \(alarm.id), retrying: \(error.localizedDescription)")
            try? alarmManager.stop(id: alarm.id)
            try? alarmManager.cancel(id: alarm.id)
            do {
                _ = try await alarmManager.schedule(id: alarm.id, configuration: config)
            } catch {
                Self.logger.error("Retry schedule failed for \(alarm.id): \(error.localizedDescription)")
            }
        }
    }

    private func makeConfiguration(
        for alarm: UserAlarm,
        schedule: Alarm.Schedule
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        let title = resolvedTitle(for: alarm)
        let sharedSettings = alarm.resolvedSharedSettings(defaults: defaultSharedSettings)
        // NOOP: Phase 4 — snooze button hidden until SnoozeIntent is implemented
        let showSnooze = false // sharedSettings.canSnoozeAgain(currentCount: alarm.snoozeCount)

        let alertPresentation = AlarmPresentation.Alert(
            title: Self.localizedResource(from: title),
            stopButton: .stopButton,
            secondaryButton: showSnooze ? .snoozeButton : nil,
            secondaryButtonBehavior: showSnooze ? .custom : nil
        )

        let presentation = AlarmPresentation(alert: alertPresentation)

        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: OpenAlarmMetadata(source: alarm.id.uuidString, isShadowTrial: alarm.isTryOut),
            tintColor: OAColor.actionCyan
        )

        let snoozeInterval: TimeInterval = sharedSettings.snoozeDurationMinutes == 0
            ? 5
            : TimeInterval(sharedSettings.snoozeDurationMinutes * 60)

        let countdownDuration: Alarm.CountdownDuration? = showSnooze
            ? .init(preAlert: nil, postAlert: snoozeInterval)
            : nil

        return .init(
            countdownDuration: countdownDuration,
            schedule: schedule,
            attributes: attributes,
            stopIntent: StopIntent(alarmID: alarm.id.uuidString),
            secondaryIntent: nil,
            sound: .default
        )
    }

    private func resolvedTitle(for alarm: UserAlarm) -> String {
        if alarm.isNap {
            return String(localized: "nap_default_alarm_label")
        }
        let trimmed = alarm.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return NSLocalizedString("alarm_editor_default_label", comment: "")
        }
        return trimmed
    }

    private static func localizedResource(from text: String) -> LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(text))
    }

    // MARK: - Observe AlarmKit Updates

    private func observeAlarmUpdates() {
        alarmUpdatesTask = Task { [weak self] in
            guard let self else { return }
            for await incoming in alarmManager.alarmUpdates {
                guard !Task.isCancelled else { return }
                self.applyRemoteAlarms(incoming)
            }
        }
    }

    private var lastKnownAlarmState: [UUID: Alarm.State] = [:]

    private func applyRemoteAlarms(_ incoming: [Alarm]) {
        let remoteByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })

        var updated = alarms
        var changed = false
        var idsToRemove: Set<UUID> = []

        for index in updated.indices {
            let alarm = updated[index]
            let previousState = lastKnownAlarmState[alarm.id]
            let currentState = remoteByID[alarm.id]?.state

            // Track state
            if let currentState {
                lastKnownAlarmState[alarm.id] = currentState
            } else {
                lastKnownAlarmState.removeValue(forKey: alarm.id)
            }

            // Detect alarm fired: alerting → non-alerting transition
            let firedTransition = previousState == .alerting && currentState != .alerting
            // Detect cold-start completion: alarm gone and was one-shot with past trigger
            let coldStartCompletion = currentState == nil && !alarm.isRepeating
                && alarm.fixedTriggerDate != nil && alarm.fixedTriggerDate! <= .now

            if firedTransition || coldStartCompletion {
                // Nap or tryOut: always remove
                if alarm.isNap || alarm.isTryOut {
                    idsToRemove.insert(alarm.id)
                    continue
                }

                // Regular alarm: delete-after-use
                if alarm.deleteAfterUse {
                    idsToRemove.insert(alarm.id)
                    continue
                }

                if alarm.isRepeating {
                    // Repeating alarm: reset snooze count, stays enabled
                    updated[index].snoozeCount = 0
                    updated[index].lifecycleState = .scheduled
                    updated[index].updatedAt = .now
                    changed = true
                } else {
                    // Non-repeating alarm kept: disable it
                    updated[index].isEnabled = false
                    updated[index].lifecycleState = .completed
                    updated[index].updatedAt = .now
                    changed = true
                }
            }

            // Update lifecycle state from remote
            if let currentState {
                let newLifecycle: AlarmLifecycleState = currentState == .alerting ? .alerting : .scheduled
                if updated[index].lifecycleState != newLifecycle {
                    updated[index].lifecycleState = newLifecycle
                    changed = true
                }
            }
        }

        // Remove completed alarms
        if !idsToRemove.isEmpty {
            for id in idsToRemove {
                try? alarmManager.stop(id: id)
                try? alarmManager.cancel(id: id)
                lastKnownAlarmState.removeValue(forKey: id)
            }
            updated.removeAll { idsToRemove.contains($0.id) }
            changed = true
        }

        // Update remote states for UI
        var newRemoteStates: [UUID: Alarm.State] = [:]
        for (id, alarm) in remoteByID {
            newRemoteStates[id] = alarm.state
        }
        remoteStates = newRemoteStates

        if changed {
            alarms = sortAlarms(updated)
            saveAlarms()
        }
    }

    // MARK: - Persistence Helpers

    private func saveAlarms() {
        persistence.saveUserAlarms(alarms)
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
}
