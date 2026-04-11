import AlarmKit
import AppIntents
import Combine
import Foundation
import os
import SwiftUI
import UserNotifications

// MARK: - DisarmPresentation

struct DisarmPresentation: Identifiable {
    let id: UUID  // alarm ID
    let alarm: AlarmDefinition
    let tasks: [AlarmTask]
}

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

    @Published var disarmPresentation: DisarmPresentation?
    @Published var wakeUpCheckConfirmationPresentation: WakeUpCheckConfirmationPresentation?
    private(set) var wakeCheckSessions: [UUID: WakeCheckSession] = [:]

    /// In-memory scheduling phases, rebuilt on launch from AlarmKit state.
    private(set) var runtimePhases: [UUID: AlarmSchedulingPhase] = [:]

    // MARK: - Computed Properties

    var activeNap: UserAlarm? {
        alarms.first { $0.isNap }
    }

    var regularAlarms: [UserAlarm] {
        alarms.filter { if case .regular = $0.type { return true } else { return false } }
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
    private let wakeCheckNotificationService: WakeUpCheckNotificationService
    private var alarmUpdatesTask: Task<Void, Never>?
    private var wakeCheckConfirmationObserver: Any?
    private var disarmChallengeObserver: Any?

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
        self.wakeCheckNotificationService = WakeUpCheckNotificationService()
        self.defaultSharedSettings = persistence.loadDefaultSharedSettings()
        self.napDefaultSharedSettings = persistence.loadNapDefaultSharedSettings()
        self.defaultNapDurationMinutes = persistence.loadDefaultNapDurationMinutes()
        self.testingModeEnabled = persistence.loadTestingModeEnabled()
        self.permissionStatus = self.permissionService.currentStatus()

        wakeCheckNotificationService.ensureCategoryRegistered()

        load()
        loadWakeCheckSessionsFromPersistence()
        rebuildRuntimePhases()
        observeAlarmUpdates()

        wakeCheckConfirmationObserver = NotificationCenter.default.addObserver(
            forName: .wakeUpCheckConfirmationRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.processPendingWakeCheckConfirmations()
            }
        }

        disarmChallengeObserver = NotificationCenter.default.addObserver(
            forName: .disarmChallengeRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.load()
                self?.processPendingDisarmChallenges()
            }
        }

    }

    deinit {
        alarmUpdatesTask?.cancel()
        if let observer = disarmChallengeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeCheckConfirmationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Load

    private func load() {
        alarms = sortAlarms(persistence.loadUserAlarms())
    }

    // MARK: - App Lifecycle

    func handleAppOpened() async {
        permissionStatus = permissionService.currentStatus()
        load()
        await refreshRemoteState()
        loadWakeCheckSessionsFromPersistence()
        rebuildRuntimePhases()
        processPendingWakeCheckConfirmations()
        showWakeCheckConfirmationIfNeeded()
        processPendingDisarmChallenges()
    }

    private func refreshRemoteState() async {
        do {
            let remote = try alarmManager.alarms
            await applyRemoteAlarms(remote)
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

        await process(event: .enabled, for: alarm.id)
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

        alarms[index] = updated

        // Any schedule change clears overrides
        alarms[index].activeOverride = nil
        alarms[index].nextTriggerOverrideDate = nil

        // Cancel any active bridge alarms from the old alarm
        if let override = alarm.activeOverride {
            for bridgeID in override.bridgeAlarmIDs {
                try? alarmManager.stop(id: bridgeID)
                try? alarmManager.cancel(id: bridgeID)
            }
        }

        alarms = sortAlarms(alarms)
        saveAlarms()

        await process(event: .updated, for: alarm.id)
    }

    // MARK: - Update Next Alarm Occurrence

    func updateNextAlarmOccurrence(_ alarm: UserAlarm, with draft: AlarmDraft) async throws {
        if permissionStatus != .authorized {
            let status = await requestPermissionIfNeeded()
            guard status == .authorized else {
                throw AlarmStoreError.permissionDenied
            }
        }

        guard let index = alarms.firstIndex(where: { $0.id == alarm.id }) else { return }
        guard alarm.isRepeating else { return }

        let calendar = Calendar.autoupdatingCurrent
        let draftComponents = calendar.dateComponents([.hour, .minute], from: draft.time)
        let modifiedHour = draftComponents.hour ?? alarm.hour
        let modifiedMinute = draftComponents.minute ?? alarm.minute

        let result = BridgeDateCalculator.bridgeDates(
            hour: alarm.hour, minute: alarm.minute,
            repeatDays: alarm.repeatDays,
            overrideKind: .modifyNext,
            modifiedTime: (hour: modifiedHour, minute: modifiedMinute),
            referenceDate: .now,
            calendar: calendar
        )

        // Cancel existing override if any
        if let existingOverride = alarms[index].activeOverride {
            for bridgeID in existingOverride.bridgeAlarmIDs {
                try? alarmManager.stop(id: bridgeID)
                try? alarmManager.cancel(id: bridgeID)
            }
        }

        let bridgeIDs = (0..<5).map { _ in UUID() }

        alarms[index].activeOverride = OverrideState(
            kind: .modifyNext,
            bridgeAlarmIDs: bridgeIDs,
            restoreAnchorDate: result.restoreAnchorDate
        )
        alarms[index].nextTriggerOverrideDate = result.bridgeDates[0]  // the modified first bridge date
        alarms[index].snoozeCount = 0
        alarms[index].updatedAt = .now
        alarms = sortAlarms(alarms)
        saveAlarms()

        // Cancel canonical schedule
        try? alarmManager.stop(id: alarm.id)
        try? alarmManager.cancel(id: alarm.id)

        // Schedule bridge alarms
        let parentAlarm = alarms.first(where: { $0.id == alarm.id }) ?? alarm
        for (i, bridgeID) in bridgeIDs.enumerated() {
            await scheduleBridgeAlarm(
                bridgeID: bridgeID,
                trigger: .fixed(result.bridgeDates[i]),
                parentAlarm: parentAlarm
            )
        }

        runtimePhases[alarm.id] = .overrideActive(bridgeAlarmIDs: Set(bridgeIDs))
    }

    // MARK: - Delete Alarm

    func deleteAlarm(_ alarm: UserAlarm) {
        // Clean up pending disarm state if active
        var pendingDisarm = persistence.loadPendingDisarmAlarmIDs()
        if pendingDisarm.remove(alarm.id) != nil {
            persistence.savePendingDisarmAlarmIDs(pendingDisarm)
        }
        if disarmPresentation?.id == alarm.id {
            disarmPresentation = nil
        }

        // Clean up wake-check session if active
        if let session = wakeCheckSessions[alarm.id] {
            wakeCheckNotificationService.cancelNotification(id: session.notificationID)
            wakeCheckSessions.removeValue(forKey: alarm.id)
            persistence.saveWakeCheckSessions(wakeCheckSessions)
        }

        if wakeUpCheckConfirmationPresentation?.id == alarm.id {
            wakeUpCheckConfirmationPresentation = nil
        }

        // Cancel and remove via state machine effects
        let currentPhase = runtimePhases[alarm.id] ?? .idle
        let settings = resolvedSettingsForAlarm(alarm)
        let result = AlarmStateMachine.transition(
            current: currentPhase,
            event: .deleted,
            alarm: alarm,
            resolvedSettings: settings
        )
        runtimePhases[alarm.id] = result.phase

        // Execute effects synchronously (delete only produces cancel + delete effects)
        for effect in result.effects {
            switch effect {
            case .cancelAlarmKit(let ids):
                for id in ids {
                    try? alarmManager.stop(id: id)
                    try? alarmManager.cancel(id: id)
                }
            case .deleteAlarm(let id):
                alarms.removeAll { $0.id == id }
                runtimePhases.removeValue(forKey: id)
                remoteStates.removeValue(forKey: id)
                saveAlarms()
            case .scheduleAlarmKit, .persist:
                break
            }
        }
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

        // Un-skip: toggling on while skip-next is active
        if enabled, alarms[index].activeOverride?.kind == .skipNext {
            await clearOverrideAndRestore(alarmIndex: index)
            return
        }

        // Skip-next: only for repeating alarms
        if !enabled, skipNext == true, alarm.isRepeating {
            await activateSkipNext(alarmIndex: index)
            return
        }

        // Normal enable/disable
        alarms[index].isEnabled = enabled
        alarms[index].snoozeCount = 0
        alarms[index].updatedAt = .now

        // If disabling and there's an active override, clear it
        if !enabled, alarms[index].activeOverride != nil {
            alarms[index].activeOverride = nil
            alarms[index].nextTriggerOverrideDate = nil
        }

        if enabled {
            alarms[index].lifecycleState = .scheduled
        }

        alarms = sortAlarms(alarms)
        saveAlarms()

        await process(event: enabled ? .enabled : .disabled, for: alarm.id)
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

        // 0 minutes = 5 seconds (testing mode)
        let napDuration: TimeInterval = draft.totalMinutes == 0 ? 5 : TimeInterval(draft.totalMinutes * 60)
        let targetDate = Date.now.addingTimeInterval(napDuration)
        let alarm = UserAlarm.makeNap(
            from: draft,
            defaultSharedSettings: resolvedNapDefaults,
            targetDate: targetDate
        )

        alarms.append(alarm)
        alarms = sortAlarms(alarms)
        saveAlarms()

        await process(event: .enabled, for: alarm.id)
    }

    // MARK: - Pause Nap

    func pauseNap() async {
        guard let nap = activeNap, !nap.isPaused else { return }

        let remaining = nap.remainingSeconds()

        guard let index = alarms.firstIndex(where: { $0.id == nap.id }) else { return }
        alarms[index].pausedRemainingSeconds = remaining
        alarms[index].updatedAt = .now
        saveAlarms()

        await process(event: .disabled, for: nap.id)
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

        await process(event: .enabled, for: nap.id)
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
            trigger: .fixed(triggerDate),
            recurrence: .none,
            type: .tryOut,
            deleteAfterUse: true,
            settingsMode: .custom(sharedSettings),
            nextTriggerOverrideDate: nil,
            isEnabled: true,
            activeOverride: nil,
            snoozeCount: 0,
            lifecycleState: .scheduled,
            createdAt: .now,
            updatedAt: .now
        )
        AlarmTypePolicy.normalizeOnWrite(&alarm)

        alarms.append(alarm)
        alarms = sortAlarms(alarms)
        saveAlarms()

        await process(event: .enabled, for: alarm.id)
    }

    // MARK: - Settings

    func updateDefaultSharedSettings(_ settings: SharedAlarmSettings) {
        guard defaultSharedSettings != settings else { return }
        defaultSharedSettings = settings
        persistence.saveDefaultSharedSettings(settings)

        // Reschedule all enabled alarms using defaults so new config takes effect.
        // This includes naps — settings are pointers, changes propagate immediately.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for alarm in self.alarms where alarm.isEnabled {
                if case .useDefault = alarm.settingsMode {
                    // Skip naps that have their own nap defaults
                    if alarm.isNap, self.napDefaultSharedSettings != nil { continue }
                    await self.forceRescheduleAlarm(alarm)
                }
            }
        }
    }

    func updateTestingModeEnabled(_ enabled: Bool) {
        testingModeEnabled = enabled
        persistence.saveTestingModeEnabled(enabled)
    }

    func updateNapDefaultSharedSettings(_ settings: SharedAlarmSettings?) {
        guard napDefaultSharedSettings != settings else { return }
        napDefaultSharedSettings = settings
        persistence.saveNapDefaultSharedSettings(settings)

        // Reschedule active nap alarms so new config takes effect immediately.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for alarm in self.alarms where alarm.isEnabled && alarm.isNap {
                if case .useDefault = alarm.settingsMode {
                    await self.forceRescheduleAlarm(alarm)
                }
            }
        }
    }

    func updateDefaultNapDurationMinutes(_ minutes: Int) {
        defaultNapDurationMinutes = max(0, minutes)
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

    // MARK: - Wake-Up Check

    func disableWakeUpCheckFeatureGlobally() {
        // Disable in global defaults
        var settings = defaultSharedSettings
        settings.wakeUpCheckEnabled = false
        updateDefaultSharedSettings(settings)

        // Disable in nap defaults if present
        if var napSettings = napDefaultSharedSettings {
            napSettings.wakeUpCheckEnabled = false
            updateNapDefaultSharedSettings(napSettings)
        }

        // Disable in all per-alarm custom settings
        var changed = false
        for index in alarms.indices {
            if !alarms[index].useDefaultSharedSettings && alarms[index].customSharedSettings.wakeUpCheckEnabled {
                alarms[index].customSharedSettings.wakeUpCheckEnabled = false
                alarms[index].updatedAt = .now
                changed = true
            }
        }

        // Cancel all active wake-check sessions
        for (alarmID, session) in wakeCheckSessions {
            wakeCheckNotificationService.cancelNotification(id: session.notificationID)
            try? alarmManager.stop(id: alarmID)
            try? alarmManager.cancel(id: alarmID)
        }
        wakeCheckSessions.removeAll()
        persistence.saveWakeCheckSessions(wakeCheckSessions)

        // Clear pending confirmation IDs
        persistence.savePendingWakeUpCheckShowConfirmUIIDs([])
        wakeUpCheckConfirmationPresentation = nil

        if changed {
            saveAlarms()
        }
    }

    func confirmWakeUpCheck(for alarmID: UUID) async {
        guard let session = wakeCheckSessions[alarmID] else { return }

        // Clean up grace tracking
        var graceApplied = loadGraceAppliedIDs()
        graceApplied.remove(alarmID)
        saveGraceAppliedIDs(graceApplied)

        // Cancel the wake-check notification and backup alarm
        wakeCheckNotificationService.cancelNotification(id: session.notificationID)
        try? alarmManager.stop(id: alarmID)
        try? alarmManager.cancel(id: alarmID)

        // Remove session
        wakeCheckSessions.removeValue(forKey: alarmID)
        persistence.saveWakeCheckSessions(wakeCheckSessions)

        // Remove from pending confirmation IDs
        var pendingIDs = persistence.loadPendingWakeUpCheckShowConfirmUIIDs()
        pendingIDs.remove(alarmID)
        persistence.savePendingWakeUpCheckShowConfirmUIIDs(pendingIDs)

        // Dismiss the confirmation UI
        if wakeUpCheckConfirmationPresentation?.id == alarmID {
            wakeUpCheckConfirmationPresentation = nil
        }

        // Restore alarm state via state machine
        guard let alarm = alarms.first(where: { $0.id == alarmID }) else { return }

        let currentPhase = runtimePhases[alarmID] ?? .awaitingWakeCheck
        let settings = resolvedSettingsForAlarm(alarm)
        let result = AlarmStateMachine.transition(
            current: currentPhase,
            event: .wakeCheckConfirmed,
            alarm: alarm,
            resolvedSettings: settings
        )
        runtimePhases[alarmID] = result.phase

        for effect in result.effects {
            await executeSideEffect(effect, for: alarm)
        }

        // Handle non-repeating kept alarms: disable (state machine returns .completed with no effects)
        if result.phase == .completed, result.effects.isEmpty {
            if let index = alarms.firstIndex(where: { $0.id == alarmID }) {
                alarms[index].isEnabled = false
                alarms[index].snoozeCount = 0
                alarms[index].lifecycleState = .completed
                alarms[index].updatedAt = .now
                saveAlarms()
            }
        }

        // Handle repeating alarms: reset snooze count
        if case .scheduled = result.phase {
            if let index = alarms.firstIndex(where: { $0.id == alarmID }) {
                alarms[index].snoozeCount = 0
                alarms[index].lifecycleState = .scheduled
                alarms[index].updatedAt = .now
                saveAlarms()
            }
        }

        if case .overrideActive = result.phase {
            if let index = alarms.firstIndex(where: { $0.id == alarmID }) {
                alarms[index].snoozeCount = 0
                alarms[index].lifecycleState = .scheduled
                alarms[index].updatedAt = .now
                saveAlarms()
            }
        }
    }

    /// Tracks which alarm IDs have already received a notification-tap grace
    /// period extension, persisted so force-quit doesn't re-extend.
    // Uses same key as StopIntent.graceAppliedKey

    func applyWakeUpCheckGracePeriodIfNeeded(for alarmID: UUID) async -> Date? {
        guard var session = wakeCheckSessions[alarmID] else { return nil }

        let remaining = session.deadlineAt.timeIntervalSinceNow
        let minimumGrace: TimeInterval = 60

        // Only extend if opened via notification tap (pending confirm UI ID present)
        // AND less than 1 minute remaining AND not already extended
        if remaining < minimumGrace, remaining > 0 {
            let graceApplied = loadGraceAppliedIDs()
            let wasTappedFromNotification = !graceApplied.contains(alarmID)
                && pendingConfirmUIContains(alarmID)

            if wasTappedFromNotification {
                let newDeadline = Date.now.addingTimeInterval(minimumGrace)
                session.deadlineAt = newDeadline
                wakeCheckSessions[alarmID] = session
                persistence.saveWakeCheckSessions(wakeCheckSessions)

                // Mark as extended so it won't extend again
                var applied = graceApplied
                applied.insert(alarmID)
                saveGraceAppliedIDs(applied)

                // Reschedule backup alarm
                if let alarm = alarms.first(where: { $0.id == alarmID }) {
                    let config = AlarmConfigurationBuilder.makeWakeCheckBackupConfiguration(for: alarm, deadlineAt: newDeadline)
                    try? alarmManager.stop(id: alarmID)
                    try? alarmManager.cancel(id: alarmID)
                    _ = try? await alarmManager.schedule(id: alarmID, configuration: config)
                }

                return newDeadline
            }
        }

        return session.deadlineAt
    }

    private func pendingConfirmUIContains(_ alarmID: UUID) -> Bool {
        persistence.loadPendingWakeUpCheckShowConfirmUIIDs().contains(alarmID)
    }

    private func loadGraceAppliedIDs() -> Set<UUID> {
        StopIntent.loadGraceAppliedIDs()
    }

    private func saveGraceAppliedIDs(_ ids: Set<UUID>) {
        StopIntent.saveGraceAppliedIDs(ids)
    }

    func shouldPresentWakeCheckPermissionDeniedPromptOnLaunch() async -> Bool {
        let status = await notificationPermissionService.currentStatus()
        notificationPermissionStatus = status

        guard status == .denied else { return false }

        // Check if any alarm has wake-check enabled
        let hasWakeCheckEnabled = alarms.contains { alarm in
            let settings = resolvedSettingsForAlarm(alarm)
            return settings.wakeUpCheckEnabled
        }

        return hasWakeCheckEnabled
    }

    // MARK: - Disarm Challenge

    private func processPendingDisarmChallenges() {
        // If challenge screen is already showing, don't replace it.
        // Re-creating the presentation causes a sound race between old/new TaskSoundManager.
        guard disarmPresentation == nil else { return }

        var pendingIDs = persistence.loadPendingDisarmAlarmIDs()
        guard let alarmKitID = pendingIDs.first else { return }

        // Resolve parent alarm — alarmKitID may be a bridge UUID
        guard let (_, index) = resolveParentAlarm(for: alarmKitID) else {
            pendingIDs.remove(alarmKitID)
            persistence.savePendingDisarmAlarmIDs(pendingIDs)
            return
        }

        // Mark alarm as awaiting disarm challenge (StopIntent only writes the pending ID,
        // all lifecycle logic lives here in the app).
        if alarms[index].lifecycleState != .awaitingDisarmChallenge {
            alarms[index].lifecycleState = .awaitingDisarmChallenge
            alarms[index].snoozeCount = 0
            alarms[index].updatedAt = .now
            saveAlarms()
            runtimePhases[alarms[index].id] = .awaitingDisarmChallenge(alarmKitID: alarmKitID)
        }

        let alarm = alarms[index]
        let settings = resolvedSettingsForAlarm(alarm)
        disarmPresentation = DisarmPresentation(
            id: alarms[index].id,
            alarm: alarm,
            tasks: settings.tasks
        )
    }

    func completeDisarmChallenge(for alarmID: UUID) async {
        let completedAlarmKitID: UUID
        if case .awaitingDisarmChallenge(let activeAlarmKitID) = runtimePhases[alarmID] {
            completedAlarmKitID = activeAlarmKitID
        } else {
            completedAlarmKitID = alarmID
        }

        // Remove from pending disarm — pending set may contain bridge UUID or parent ID
        var pendingIDs = persistence.loadPendingDisarmAlarmIDs()
        pendingIDs.remove(alarmID)
        pendingIDs.remove(completedAlarmKitID)
        // Also remove any bridge IDs for this alarm
        if let override = alarms.first(where: { $0.id == alarmID })?.activeOverride {
            for bridgeID in override.bridgeAlarmIDs {
                pendingIDs.remove(bridgeID)
            }
        }
        persistence.savePendingDisarmAlarmIDs(pendingIDs)

        // Dismiss the UI
        if disarmPresentation?.id == alarmID {
            disarmPresentation = nil
        }

        guard let alarm = alarms.first(where: { $0.id == alarmID }) else { return }
        let settings = resolvedSettingsForAlarm(alarm)

        // Process through state machine
        await process(event: .challengeCompleted(alarmKitID: completedAlarmKitID), for: alarmID)

        let phase = runtimePhases[alarmID]

        // Handle wake-check (previously in StopIntent) — trust the state machine
        if phase == .awaitingWakeCheck {
            await startWakeCheckSession(for: alarmID, alarm: alarm, settings: settings)
        }

        // Handle completion for non-repeating kept alarms
        if phase == .completed {
            if let index = alarms.firstIndex(where: { $0.id == alarmID }) {
                if !alarms[index].isRepeating && !alarms[index].deleteAfterUse {
                    alarms[index].isEnabled = false
                    alarms[index].lifecycleState = .completed
                    alarms[index].updatedAt = .now
                    saveAlarms()
                }
            }
        }

        // Handle repeating re-arm
        if case .scheduled = phase {
            if let index = alarms.firstIndex(where: { $0.id == alarmID }) {
                alarms[index].snoozeCount = 0
                alarms[index].lifecycleState = .scheduled
                alarms[index].updatedAt = .now
                saveAlarms()
            }
        }

        if case .overrideActive = phase, let index = alarms.firstIndex(where: { $0.id == alarmID }) {
            alarms[index].snoozeCount = 0
            alarms[index].lifecycleState = .scheduled
            alarms[index].updatedAt = .now
            saveAlarms()
        }

        // Refresh bridge runtime IDs after returning to override-active.
        if case .overrideActive = phase, let override = alarms.first(where: { $0.id == alarmID })?.activeOverride {
            let runtimeAlarms = (try? alarmManager.alarms) ?? []
            let runtimeIDs = Set(runtimeAlarms.map { $0.id })
            let liveBridgeIDs = Set(override.bridgeAlarmIDs.filter { runtimeIDs.contains($0) })
            runtimePhases[alarmID] = .overrideActive(bridgeAlarmIDs: liveBridgeIDs)
        }

        // Process next pending disarm if any
        processPendingDisarmChallenges()
    }

    private func startWakeCheckSession(for alarmID: UUID, alarm: AlarmDefinition, settings: SharedAlarmSettings) async {
        let previousSession = wakeCheckSessions[alarmID]
        let existingCycle = previousSession?.cycle ?? 0
        let newCycle = existingCycle + 1

        // Cancel previous notification
        if let previousNotificationID = previousSession?.notificationID {
            wakeCheckNotificationService.cancelNotification(id: previousNotificationID)
        }

        // Clear grace period
        var graceApplied = loadGraceAppliedIDs()
        graceApplied.remove(alarmID)
        saveGraceAppliedIDs(graceApplied)

        // Clear pending confirm UI
        var pendingConfirmUIIDs = persistence.loadPendingWakeUpCheckShowConfirmUIIDs()
        pendingConfirmUIIDs.remove(alarmID)
        persistence.savePendingWakeUpCheckShowConfirmUIIDs(pendingConfirmUIIDs)

        let checkDelay = WakeUpCheckTimingPolicy.checkDelayInterval(for: settings.wakeUpCheckDelayMinutes)
        let responseTimeout = WakeUpCheckTimingPolicy.responseTimeoutInterval(for: settings.wakeUpCheckResponseTimeoutMinutes)
        let checkAt = Date.now.addingTimeInterval(checkDelay)
        let deadlineAt = checkAt.addingTimeInterval(responseTimeout)
        let notificationID = WakeUpCheckNotificationConstants.notificationID(alarmID: alarmID, cycle: newCycle)

        let session = WakeCheckSession(
            alarmID: alarmID,
            cycle: newCycle,
            checkAt: checkAt,
            deadlineAt: deadlineAt,
            notificationID: notificationID
        )
        wakeCheckSessions[alarmID] = session
        persistence.saveWakeCheckSessions(wakeCheckSessions)

        // Update lifecycle state
        if let index = alarms.firstIndex(where: { $0.id == alarmID }) {
            alarms[index].lifecycleState = .awaitingWakeCheck
            alarms[index].updatedAt = .now
            saveAlarms()
        }

        // Schedule notification
        let notifCenter = UNUserNotificationCenter.current()
        let notifSettings = await notifCenter.notificationSettings()
        if notifSettings.authorizationStatus == .authorized {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "wake_check_notification_title")
            content.body = String(localized: "wake_check_notification_body")
            content.sound = .default
            content.categoryIdentifier = WakeUpCheckNotificationConstants.categoryID
            content.userInfo = [
                WakeUpCheckNotificationConstants.alarmIDUserInfoKey: alarmID.uuidString,
                WakeUpCheckNotificationConstants.cycleUserInfoKey: newCycle,
            ]

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, checkDelay), repeats: false)
            let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: trigger)
            try? await notifCenter.add(request)
        }

        // Schedule backup alarm at deadline
        let config = AlarmConfigurationBuilder.makeWakeCheckBackupConfiguration(for: alarm, deadlineAt: deadlineAt)
        _ = try? await alarmManager.schedule(id: alarmID, configuration: config)
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
        case .awaitingDisarmChallenge:
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

    /// Force-reschedule: stops and cancels before scheduling.
    /// Used when updating config on an already-active alarm.
    private func forceRescheduleAlarm(_ alarm: UserAlarm) async {
        if let override = alarm.activeOverride {
            // Cancel all existing bridge alarms
            for bridgeID in override.bridgeAlarmIDs {
                try? alarmManager.stop(id: bridgeID)
                try? alarmManager.cancel(id: bridgeID)
            }

            // Recalculate bridge dates and create fresh UUIDs
            let calendar = Calendar.autoupdatingCurrent
            let modifiedTime: (hour: Int, minute: Int)? = override.kind == .modifyNext
                ? alarm.nextTriggerOverrideDate.map { date in
                    (calendar.component(.hour, from: date), calendar.component(.minute, from: date))
                }
                : nil

            let result = BridgeDateCalculator.bridgeDates(
                hour: alarm.hour, minute: alarm.minute,
                repeatDays: alarm.repeatDays,
                overrideKind: override.kind,
                modifiedTime: modifiedTime,
                referenceDate: .now,
                calendar: calendar
            )

            let newBridgeIDs = (0..<5).map { _ in UUID() }
            var updatedAlarm = alarm
            updatedAlarm.activeOverride = OverrideState(
                kind: override.kind,
                bridgeAlarmIDs: newBridgeIDs,
                restoreAnchorDate: override.restoreAnchorDate
            )

            if let index = alarms.firstIndex(where: { $0.id == alarm.id }) {
                alarms[index] = updatedAlarm
                saveAlarms()
            }

            runtimePhases[alarm.id] = .overrideActive(bridgeAlarmIDs: Set(newBridgeIDs))

            for (i, bridgeID) in newBridgeIDs.enumerated() {
                await scheduleBridgeAlarm(
                    bridgeID: bridgeID,
                    trigger: .fixed(result.bridgeDates[i]),
                    parentAlarm: updatedAlarm
                )
            }
        } else {
            // Normal reschedule (existing path)
            try? alarmManager.stop(id: alarm.id)
            try? alarmManager.cancel(id: alarm.id)

            let runtimeSchedule = AlarmScheduleResolver.runtimeSchedule(for: alarm)
            let config = makeConfiguration(for: alarm, schedule: runtimeSchedule)
            do {
                _ = try await alarmManager.schedule(id: alarm.id, configuration: config)
            } catch {
                Self.logger.error("Force reschedule failed for \(alarm.id): \(error.localizedDescription)")
            }
        }
    }

    private func scheduleAlarm(_ alarm: UserAlarm) async {
        if alarm.activeOverride != nil {
            Self.logger.warning("Skipping canonical schedule for \(alarm.id) because override is still active")
            return
        }

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

    private func activateSkipNext(alarmIndex index: Int) async {
        let alarm = alarms[index]
        let calendar = Calendar.autoupdatingCurrent

        let result = BridgeDateCalculator.bridgeDates(
            hour: alarm.hour, minute: alarm.minute,
            repeatDays: alarm.repeatDays,
            overrideKind: .skipNext,
            modifiedTime: nil,
            referenceDate: .now,
            calendar: calendar
        )

        let bridgeIDs = (0..<5).map { _ in UUID() }

        if let existingOverride = alarms[index].activeOverride {
            for bridgeID in existingOverride.bridgeAlarmIDs {
                try? alarmManager.stop(id: bridgeID)
                try? alarmManager.cancel(id: bridgeID)
            }
        }

        alarms[index].isEnabled = false
        alarms[index].snoozeCount = 0
        alarms[index].activeOverride = OverrideState(
            kind: .skipNext,
            bridgeAlarmIDs: bridgeIDs,
            restoreAnchorDate: result.restoreAnchorDate
        )
        alarms[index].nextTriggerOverrideDate = nil
        alarms[index].updatedAt = .now
        alarms = sortAlarms(alarms)
        saveAlarms()

        // Cancel canonical schedule
        try? alarmManager.stop(id: alarm.id)
        try? alarmManager.cancel(id: alarm.id)

        // Schedule bridge alarms
        let parentAlarm = alarms.first(where: { $0.id == alarm.id }) ?? alarm
        for (i, bridgeID) in bridgeIDs.enumerated() {
            await scheduleBridgeAlarm(
                bridgeID: bridgeID,
                trigger: .fixed(result.bridgeDates[i]),
                parentAlarm: parentAlarm
            )
        }

        runtimePhases[alarm.id] = .overrideActive(bridgeAlarmIDs: Set(bridgeIDs))
    }

    private func clearOverrideAndRestore(alarmIndex index: Int) async {
        let alarm = alarms[index]

        // Cancel bridge alarms
        if let override = alarm.activeOverride {
            for bridgeID in override.bridgeAlarmIDs {
                try? alarmManager.stop(id: bridgeID)
                try? alarmManager.cancel(id: bridgeID)
            }
        }

        alarms[index].activeOverride = nil
        alarms[index].nextTriggerOverrideDate = nil
        alarms[index].isEnabled = true
        alarms[index].snoozeCount = 0
        alarms[index].lifecycleState = .scheduled
        alarms[index].updatedAt = .now
        alarms = sortAlarms(alarms)
        saveAlarms()

        await process(event: .enabled, for: alarm.id)
    }

    private func scheduleBridgeAlarm(bridgeID: UUID, trigger: AlarmTrigger, parentAlarm: AlarmDefinition) async {
        guard case .fixed(let date) = trigger else { return }

        let config = AlarmConfigurationBuilder.makeBridgeConfiguration(
            for: parentAlarm,
            bridgeID: bridgeID,
            schedule: .fixed(date),
            defaultSharedSettings: resolvedDefaultsForAlarm(parentAlarm)
        )

        do {
            _ = try await alarmManager.schedule(id: bridgeID, configuration: config)
        } catch {
            Self.logger.warning("Bridge schedule failed for \(bridgeID), retrying: \(error.localizedDescription)")
            try? alarmManager.stop(id: bridgeID)
            try? alarmManager.cancel(id: bridgeID)
            do {
                _ = try await alarmManager.schedule(id: bridgeID, configuration: config)
            } catch {
                Self.logger.error("Bridge retry failed for \(bridgeID): \(error.localizedDescription)")
            }
        }
    }

    private func makeConfiguration(
        for alarm: UserAlarm,
        schedule: Alarm.Schedule
    ) -> AlarmManager.AlarmConfiguration<OpenAlarmMetadata> {
        AlarmConfigurationBuilder.makeConfiguration(
            for: alarm,
            schedule: schedule,
            defaultSharedSettings: resolvedDefaultsForAlarm(alarm)
        )
    }

    /// Returns the effective default settings for the given alarm.
    /// Nap alarms use nap-specific defaults (if configured), others use global defaults.
    private func resolvedDefaultsForAlarm(_ alarm: UserAlarm) -> SharedAlarmSettings {
        alarm.isNap ? resolvedNapDefaults : defaultSharedSettings
    }

    /// Returns the fully resolved settings for the given alarm (custom or cascaded defaults).
    private func resolvedSettingsForAlarm(_ alarm: UserAlarm) -> SharedAlarmSettings {
        alarm.resolvedSharedSettings(defaults: resolvedDefaultsForAlarm(alarm))
    }

    // MARK: - Bridge Alarm Resolution

    /// Resolves the parent alarm for a given AlarmKit ID. Returns the alarm directly if the ID
    /// matches an alarm's own ID, or scans activeOverride.bridgeAlarmIDs for bridge alarms.
    private func resolveParentAlarm(for alarmKitID: UUID) -> (alarm: AlarmDefinition, index: Int)? {
        if let index = alarms.firstIndex(where: { $0.id == alarmKitID }) {
            return (alarms[index], index)
        }
        if let index = alarms.firstIndex(where: { $0.activeOverride?.bridgeAlarmIDs.contains(alarmKitID) == true }) {
            return (alarms[index], index)
        }
        return nil
    }

    // MARK: - State Machine

    /// Routes a state-changing event through AlarmStateMachine and executes
    /// the returned side effects. This keeps transitions explicit and testable.
    func process(event: AlarmEvent, for alarmID: UUID) async {
        guard let alarm = alarms.first(where: { $0.id == alarmID }) else { return }

        let currentPhase = runtimePhases[alarmID] ?? .idle
        let settings = resolvedSettingsForAlarm(alarm)

        let result = AlarmStateMachine.transition(
            current: currentPhase,
            event: event,
            alarm: alarm,
            resolvedSettings: settings
        )

        runtimePhases[alarmID] = result.phase

        for effect in result.effects {
            await executeSideEffect(effect, for: alarm)
        }
    }

    private func executeSideEffect(_ effect: SchedulingSideEffect, for alarm: AlarmDefinition) async {
        switch effect {
        case .scheduleAlarmKit:
            await scheduleAlarm(alarm)
        case .cancelAlarmKit(let ids):
            for id in ids {
                try? alarmManager.stop(id: id)
                try? alarmManager.cancel(id: id)
            }
        case .deleteAlarm(let id):
            alarms.removeAll { $0.id == id }
            runtimePhases.removeValue(forKey: id)
            remoteStates.removeValue(forKey: id)
            saveAlarms()
        case .persist(let updatedAlarm):
            if let index = alarms.firstIndex(where: { $0.id == updatedAlarm.id }) {
                alarms[index] = updatedAlarm
                saveAlarms()
            }
        }
    }

    private func rebuildRuntimePhases() {
        let runtimeAlarms: [Alarm]
        do {
            runtimeAlarms = try alarmManager.alarms
        } catch {
            runtimePhases = [:]
            return
        }
        let runtimeByID = Dictionary(uniqueKeysWithValues: runtimeAlarms.map { ($0.id, $0) })

        alarmLoop: for alarm in alarms {
            // Persisted lifecycle state takes priority for post-alerting phases.
            // AlarmKit may still report .alerting briefly after StopIntent runs.
            if alarm.lifecycleState == .awaitingDisarmChallenge {
                runtimePhases[alarm.id] = .awaitingDisarmChallenge(alarmKitID: alarm.id)
            } else if alarm.lifecycleState == .awaitingWakeCheck {
                runtimePhases[alarm.id] = .awaitingWakeCheck
            } else if let override = alarm.activeOverride {
                // Override-active alarms: check bridge IDs in AlarmKit
                // The canonical alarm.id is NOT in AlarmKit when an override is active —
                // only bridge IDs are registered.
                for bridgeID in override.bridgeAlarmIDs {
                    if let bridgeRuntime = runtimeByID[bridgeID] {
                        switch bridgeRuntime.state {
                        case .alerting:
                            runtimePhases[alarm.id] = .alerting(alarmKitID: bridgeID)
                            continue alarmLoop
                        case .paused:
                            runtimePhases[alarm.id] = .snoozed(alarmKitID: bridgeID)
                            continue alarmLoop
                        case .scheduled, .countdown:
                            break  // bridge is alive, will be collected below
                        @unknown default:
                            break
                        }
                    }
                }

                // No bridge in active lifecycle — set to overrideActive with live bridge IDs
                let liveBridgeIDs = Set(override.bridgeAlarmIDs.filter { runtimeByID[$0] != nil })
                runtimePhases[alarm.id] = .overrideActive(bridgeAlarmIDs: liveBridgeIDs)
                continue alarmLoop
            } else if let runtime = runtimeByID[alarm.id] {
                switch runtime.state {
                case .alerting:
                    runtimePhases[alarm.id] = .alerting(alarmKitID: alarm.id)
                case .scheduled, .countdown:
                    if alarm.snoozeCount > 0 {
                        runtimePhases[alarm.id] = .snoozed(alarmKitID: alarm.id)
                    } else {
                        runtimePhases[alarm.id] = .scheduled(alarmKitIDs: [alarm.id])
                    }
                case .paused:
                    runtimePhases[alarm.id] = .snoozed(alarmKitID: alarm.id)
                @unknown default:
                    runtimePhases[alarm.id] = .idle
                }
            } else if alarm.isEnabled {
                runtimePhases[alarm.id] = .idle
            } else {
                runtimePhases[alarm.id] = .idle
            }
        }
    }

    // MARK: - Observe AlarmKit Updates

    private func observeAlarmUpdates() {
        alarmUpdatesTask = Task { [weak self] in
            guard let self else { return }
            for await incoming in alarmManager.alarmUpdates {
                guard !Task.isCancelled else { return }
                await self.applyRemoteAlarms(incoming)
            }
        }
    }

    private func applyRemoteAlarms(_ incoming: [Alarm]) async {
        // Intents write the truth to persistence. We just reload and sync.
        let persistedAlarms = persistence.loadUserAlarms()
        wakeCheckSessions = persistence.loadWakeCheckSessions()

        // Update remote states for UI
        let remoteByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        var newRemoteStates: [UUID: Alarm.State] = [:]
        for (id, alarm) in remoteByID {
            newRemoteStates[id] = alarm.state
        }
        remoteStates = newRemoteStates

        // Pure reload — no cleanup, no deletion, no races with intents.
        alarms = sortAlarms(persistedAlarms)

        rebuildRuntimePhases()

        // Restore canonical schedule for any overrides whose restore anchor has passed
        await reconcileOverrides()

        // Process any pending wake-check confirmation UI
        processPendingWakeCheckConfirmations()

        // Process any pending disarm challenges
        processPendingDisarmChallenges()
    }

    private func reconcileOverrides() async {
        let now = Date.now

        for (index, alarm) in alarms.enumerated() {
            guard let override = alarm.activeOverride else { continue }
            guard now > override.restoreAnchorDate else { continue }

            // Don't restore if a bridge alarm is mid-lifecycle
            let phase = runtimePhases[alarm.id] ?? .idle
            switch phase {
            case .alerting, .snoozed, .awaitingDisarmChallenge, .awaitingWakeCheck:
                continue  // bridge in flight, skip until lifecycle completes
            default:
                break
            }

            // Cancel remaining bridge alarms
            for bridgeID in override.bridgeAlarmIDs {
                try? alarmManager.stop(id: bridgeID)
                try? alarmManager.cancel(id: bridgeID)
            }

            // Restore alarm state
            alarms[index].activeOverride = nil
            alarms[index].nextTriggerOverrideDate = nil
            if alarm.isSkippingNext {
                alarms[index].isEnabled = true
            }
            alarms[index].lifecycleState = .scheduled
            alarms[index].snoozeCount = 0
            alarms[index].updatedAt = .now

            // Schedule canonical repeating alarm
            let restoredAlarm = alarms[index]
            let runtimeSchedule = AlarmScheduleResolver.runtimeSchedule(for: restoredAlarm)
            let config = makeConfiguration(for: restoredAlarm, schedule: runtimeSchedule)
            do {
                _ = try await alarmManager.schedule(id: restoredAlarm.id, configuration: config)
                runtimePhases[restoredAlarm.id] = .scheduled(alarmKitIDs: [restoredAlarm.id])
            } catch {
                Self.logger.error("Override restore schedule failed for \(restoredAlarm.id): \(error.localizedDescription)")
            }
        }

        alarms = sortAlarms(alarms)
        saveAlarms()
    }

    // cleanupStaleAlarms removed — every alarm that fires goes through
    // StopIntent → pendingDisarm → completeDisarmChallenge → state machine,
    // which handles deletion/re-arm. No cleanup needed on the hot path.

    // MARK: - Wake-Up Check Helpers

    private func loadWakeCheckSessionsFromPersistence() {
        wakeCheckSessions = persistence.loadWakeCheckSessions()

        // Clean up expired sessions (deadline passed and alarm no longer exists or is not in wake-check state)
        var cleaned = false
        for (alarmID, session) in wakeCheckSessions {
            let alarmExists = alarms.contains { $0.id == alarmID }
            if !alarmExists {
                wakeCheckSessions.removeValue(forKey: alarmID)
                wakeCheckNotificationService.cancelNotification(id: session.notificationID)
                cleaned = true
            }
        }
        if cleaned {
            persistence.saveWakeCheckSessions(wakeCheckSessions)
        }
    }

    private func processPendingWakeCheckConfirmations() {
        let pendingIDs = persistence.loadPendingWakeUpCheckShowConfirmUIIDs()
        guard let firstID = pendingIDs.first else { return }

        guard wakeUpCheckConfirmationPresentation == nil else { return }

        guard let session = wakeCheckSessions[firstID] else {
            // No active session, clear this pending ID
            var updated = pendingIDs
            updated.remove(firstID)
            persistence.savePendingWakeUpCheckShowConfirmUIIDs(updated)
            return
        }

        // Only show confirmation UI after the check delay has passed
        if session.checkAt > .now {
            // Schedule showing the UI when checkAt arrives
            let delay = session.checkAt.timeIntervalSinceNow
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0.1, delay)))
                self?.processPendingWakeCheckConfirmations()
            }
            return
        }

        wakeUpCheckConfirmationPresentation = WakeUpCheckConfirmationPresentation(id: firstID)
    }

    /// Shows the wake-check confirmation UI if there's an active session
    /// past its checkAt time, even if the user didn't tap the notification.
    private func showWakeCheckConfirmationIfNeeded() {
        guard wakeUpCheckConfirmationPresentation == nil else { return }

        // Find any active session where checkAt has passed and deadline hasn't
        for (alarmID, session) in wakeCheckSessions {
            guard session.checkAt <= .now, session.deadlineAt > .now else { continue }
            guard alarms.contains(where: { $0.id == alarmID }) else { continue }

            wakeUpCheckConfirmationPresentation = WakeUpCheckConfirmationPresentation(id: alarmID)
            return
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
