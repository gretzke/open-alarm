import ActivityKit
import AlarmKit
import AppIntents
import Combine
import Foundation
import os
import SwiftUI
import UIKit
import UserNotifications

// MARK: - DisarmPresentation

struct DisarmPresentation: Identifiable {
    let id: UUID  // alarm ID
    let alarm: AlarmDefinition
    let tasks: [AlarmTask]
    let resolvedSettings: SharedAlarmSettings
}

struct AlarmListPresentation: Identifiable {
    let alarm: UserAlarm
    let isInteractive: Bool

    var id: UUID { alarm.id }
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
    @Published var liveActivitiesEnabled: Bool
    @Published var liveActivitiesSystemEnabled: Bool
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
        regularAlarmPresentations.map(\.alarm)
    }

    var regularAlarmPresentations: [AlarmListPresentation] {
        alarms.compactMap { alarm in
            guard case .regular = alarm.type else {
                return nil
            }

            switch AlarmListDisplayPolicy.presentation(
                for: alarm,
                hasActiveWakeCheckSession: wakeCheckSessions[alarm.id] != nil
            ) {
            case .hide:
                return nil
            case .show(let displayAlarm, let isInteractive):
                return AlarmListPresentation(alarm: displayAlarm, isInteractive: isInteractive)
            }
        }
    }

    var useGlobalDefaultsForNap: Bool {
        napDefaultSharedSettings == nil
    }

    /// Returns the effective defaults for nap alarms (nap-specific or global)
    var resolvedNapDefaults: SharedAlarmSettings {
        napDefaultSharedSettings ?? defaultSharedSettings
    }

    var areNapLiveActivitiesEnabled: Bool {
        liveActivitiesSystemEnabled && liveActivitiesEnabled
    }

    private var isInteractivelyVisible: Bool {
        UIApplication.shared.isProtectedDataAvailable
            && UIApplication.shared.connectedScenes.contains { scene in
                scene.activationState == .foregroundActive
            }
    }

    // MARK: - Dependencies

    private let alarmManager: AlarmManager
    private let permissionService: AlarmPermissionService
    private let notificationPermissionService: NotificationPermissionService
    private let persistence: AlarmPersistence
    private let wakeCheckNotificationService: WakeUpCheckNotificationService
    private var alarmUpdatesTask: Task<Void, Never>?
    private var settingsRescheduleTask: Task<Void, Never>?
    private var wakeCheckConfirmationObserver: Any?
    private var disarmChallengeObserver: Any?
    private var protectedDataAvailableObserver: Any?
    private var isProcessingPendingDisarms = false
    /// Pending delayed wake-check-UI presentation; replaced (not stacked) when
    /// processPendingWakeCheckConfirmations reschedules itself.
    private var pendingWakeCheckUITask: Task<Void, Never>?

    // MARK: - Init

    init(
        alarmManager: AlarmManager = .shared,
        permissionService: AlarmPermissionService? = nil,
        notificationPermissionService: NotificationPermissionService? = nil,
        userDefaults: UserDefaults? = nil
    ) {
        let resolvedDefaults = userDefaults ?? OpenAlarmSharedDefaults.userDefaults
        if userDefaults == nil {
            AlarmPersistence.migrateStandardStoreIfNeeded()
        }
        BackstopSlotStore.migrateLegacySlotIfNeeded(defaults: resolvedDefaults)
        self.alarmManager = alarmManager
        self.permissionService = permissionService ?? AlarmPermissionService(manager: alarmManager)
        self.notificationPermissionService = notificationPermissionService ?? NotificationPermissionService()
        self.persistence = AlarmPersistence(defaults: resolvedDefaults)
        self.wakeCheckNotificationService = WakeUpCheckNotificationService()
        self.defaultSharedSettings = persistence.loadDefaultSharedSettings()
        self.napDefaultSharedSettings = persistence.loadNapDefaultSharedSettings()
        self.defaultNapDurationMinutes = persistence.loadDefaultNapDurationMinutes()
        self.testingModeEnabled = persistence.loadTestingModeEnabled()
        self.liveActivitiesEnabled = persistence.loadLiveActivitiesEnabled()
        self.liveActivitiesSystemEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        self.permissionStatus = self.permissionService.currentStatus()

        if !liveActivitiesSystemEnabled && liveActivitiesEnabled {
            self.liveActivitiesEnabled = false
            persistence.saveLiveActivitiesEnabled(false)
        }

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
                await self?.processPendingDisarmChallenges()
            }
        }

        protectedDataAvailableObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleAppOpened()
            }
        }
    }

    deinit {
        alarmUpdatesTask?.cancel()
        pendingWakeCheckUITask?.cancel()
        if let observer = protectedDataAvailableObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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

    private func syncNapLiveActivity() {
        guard areNapLiveActivitiesEnabled else {
            NapCountdownLiveActivityManager.shared.stop()
            return
        }

        NapCountdownLiveActivityManager.shared.sync(with: activeNap)
    }

    // MARK: - App Lifecycle

    func handleAppOpened() async {
        permissionStatus = permissionService.currentStatus()
        refreshLiveActivityAuthorizationStatus()
        load()
        await refreshRemoteState()
        loadWakeCheckSessionsFromPersistence()
        rebuildRuntimePhases()
        sweepStaleBackstops()
        processPendingWakeCheckConfirmations()
        showWakeCheckConfirmationIfNeeded()
        await processPendingDisarmChallenges()
        syncNapLiveActivity()
    }

    func handleOpenURL(_ url: URL) async {
        guard url.scheme == "openalarm" else {
            return
        }

        guard url.host == "nap", url.path == "/extend",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let minutesValue = components.queryItems?.first(where: { $0.name == "minutes" })?.value else {
            return
        }

        guard let minutes = Int(minutesValue) else {
            Self.logger.warning("Ignoring nap extension URL with invalid minutes value: \(minutesValue, privacy: .public)")
            return
        }

        let clampedMinutes = min(
            SchedulingConstants.maxNapExtensionDeepLinkMinutes,
            max(SchedulingConstants.minNapExtensionDeepLinkMinutes, minutes)
        )
        if clampedMinutes != minutes {
            Self.logger.warning("Clamped nap extension URL minutes from \(minutes) to \(clampedMinutes)")
        }

        let napID = components.queryItems?
            .first(where: { $0.name == "id" })?
            .value
            .flatMap(UUID.init(uuidString:))

        await extendNap(byMinutes: clampedMinutes, matchingID: napID)
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

        let bridgeIDs = (0..<SchedulingConstants.bridgeWindowSize).map { _ in UUID() }

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

        // Cancel canonical schedule and enter override phase via the state machine
        await process(event: .overrideActivated(bridgeAlarmIDs: Set(bridgeIDs)), for: alarm.id)

        // Schedule bridge alarms
        guard let parentAlarm = alarms.first(where: { $0.id == alarm.id }) else { return }
        for (i, bridgeID) in bridgeIDs.enumerated() {
            await scheduleBridgeAlarm(
                bridgeID: bridgeID,
                trigger: .fixed(result.bridgeDates[i]),
                parentAlarm: parentAlarm
            )
        }
    }

    // MARK: - Delete Alarm

    func deleteAlarm(_ alarm: UserAlarm) {
        let shouldStopNapActivity = alarm.isNap

        // Clean up pending disarm state if active
        var pendingDisarm = persistence.loadPendingDisarmAlarmIDs()
        if pendingDisarm.remove(alarm.id) != nil {
            persistence.savePendingDisarmAlarmIDs(pendingDisarm)
        }
        if disarmPresentation?.id == alarm.id {
            disarmPresentation = nil
        }

        if let backstopID = BackstopSlotStore.clear(forParent: alarm.id) {
            try? alarmManager.stop(id: backstopID)
            try? alarmManager.cancel(id: backstopID)
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

        if shouldStopNapActivity {
            NapCountdownLiveActivityManager.shared.stop()
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
        let napDuration: TimeInterval = draft.totalMinutes == 0
            ? SchedulingConstants.debugSentinelSeconds
            : TimeInterval(draft.totalMinutes * 60)
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
        syncNapLiveActivity()
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
        syncNapLiveActivity()
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
        syncNapLiveActivity()
    }

    // MARK: - Extend Nap

    func extendNap(byMinutes minutes: Int) async {
        await extendNap(byMinutes: minutes, matchingID: nil)
    }

    func extendNap(byMinutes minutes: Int, matchingID napID: UUID?) async {
        guard minutes > 0, let nap = activeNap,
              napID == nil || nap.id == napID,
              let index = alarms.firstIndex(where: { $0.id == nap.id }) else { return }

        let addedSeconds = TimeInterval(minutes * 60)
        alarms[index].durationMinutes = max(0, (alarms[index].durationMinutes ?? 0) + minutes)
        alarms[index].updatedAt = .now

        if let pausedRemaining = alarms[index].pausedRemainingSeconds {
            alarms[index].pausedRemainingSeconds = pausedRemaining + addedSeconds
            saveAlarms()
            syncNapLiveActivity()
            return
        }

        let currentTarget = alarms[index].fixedTriggerDate ?? .now
        alarms[index].fixedTriggerDate = currentTarget.addingTimeInterval(addedSeconds)
        saveAlarms()

        await process(event: .updated, for: nap.id)
        syncNapLiveActivity()
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
        let previousTask = settingsRescheduleTask
        settingsRescheduleTask = Task { @MainActor [weak self, previousTask] in
            await previousTask?.value
            guard let self else { return }
            for alarm in self.alarms where alarm.isEnabled && !alarm.isPaused {
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

    @discardableResult
    func refreshLiveActivityAuthorizationStatus() -> Bool {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        liveActivitiesSystemEnabled = enabled

        if !enabled && liveActivitiesEnabled {
            liveActivitiesEnabled = false
            persistence.saveLiveActivitiesEnabled(false)
        }

        if areNapLiveActivitiesEnabled {
            syncNapLiveActivity()
        } else {
            NapCountdownLiveActivityManager.shared.stop()
        }

        return enabled
    }

    func updateLiveActivitiesEnabled(_ enabled: Bool) {
        guard liveActivitiesEnabled != enabled else { return }
        liveActivitiesEnabled = enabled
        persistence.saveLiveActivitiesEnabled(enabled)

        if areNapLiveActivitiesEnabled {
            syncNapLiveActivity()
        } else {
            NapCountdownLiveActivityManager.shared.stop()
        }
    }

    func updateNapDefaultSharedSettings(_ settings: SharedAlarmSettings?) {
        guard napDefaultSharedSettings != settings else { return }
        napDefaultSharedSettings = settings
        persistence.saveNapDefaultSharedSettings(settings)

        // Reschedule active nap alarms so new config takes effect immediately.
        let previousTask = settingsRescheduleTask
        settingsRescheduleTask = Task { @MainActor [weak self, previousTask] in
            await previousTask?.value
            guard let self else { return }
            for alarm in self.alarms where alarm.isEnabled && alarm.isNap && !alarm.isPaused {
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

        // Post-confirmation bookkeeping (snooze reset, lifecycleState, disable)
        // is persisted by the state machine's `.persist` effect.
        var effectAlarm = alarm
        for effect in result.effects {
            await executeSideEffect(effect, for: effectAlarm)
            if case .persist(let updated) = effect {
                effectAlarm = updated
            }
        }
    }

    /// Tracks which alarm IDs have already received a notification-tap grace
    /// period extension, persisted so force-quit doesn't re-extend.
    // Uses same key as StopIntent.graceAppliedKey

    func applyWakeUpCheckGracePeriodIfNeeded(for alarmID: UUID) async -> Date? {
        guard var session = wakeCheckSessions[alarmID] else { return nil }

        let remaining = session.deadlineAt.timeIntervalSinceNow
        let minimumGrace = SchedulingConstants.wakeCheckGraceMinimumSeconds

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
                    let settings = resolvedSettingsForAlarm(alarm)
                    let config = AlarmConfigurationBuilder.makeWakeCheckBackupConfiguration(
                        for: alarm,
                        deadlineAt: newDeadline,
                        resolvedSettings: settings
                    )
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

    private func processPendingDisarmChallenges() async {
        guard !isProcessingPendingDisarms else { return }

        // Never present challenge covers from a process the user cannot see.
        guard isInteractivelyVisible else {
            IntentDiagnostics.log("AlarmStore disarm presentation blocked interactiveVisible=false")
            return
        }

        isProcessingPendingDisarms = true
        defer { isProcessingPendingDisarms = false }

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
            await process(event: .disarmRequested(alarmKitID: alarmKitID), for: alarms[index].id)
        }

        let alarm = alarms[index]
        let settings = resolvedSettingsForAlarm(alarm)
        disarmPresentation = DisarmPresentation(
            id: alarms[index].id,
            alarm: alarm,
            tasks: settings.tasks,
            resolvedSettings: settings
        )
        IntentDiagnostics.log("AlarmStore disarm presentation shown alarm=\(alarm.id.uuidString)")
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

        // Post-lifecycle bookkeeping (snooze reset, lifecycleState, disable) is
        // persisted by the state machine's `.persist` effect.

        // Handle wake-check (previously in StopIntent) — trust the state machine
        if phase == .awaitingWakeCheck {
            await startWakeCheckSession(for: alarmID, alarm: alarm, settings: settings)
        }

        // Refresh bridge runtime IDs after returning to override-active.
        if case .overrideActive = phase, let override = alarms.first(where: { $0.id == alarmID })?.activeOverride {
            let runtimeAlarms = (try? alarmManager.alarms) ?? []
            let runtimeIDs = Set(runtimeAlarms.map { $0.id })
            let liveBridgeIDs = Set(override.bridgeAlarmIDs.filter { runtimeIDs.contains($0) })
            runtimePhases[alarmID] = .overrideActive(bridgeAlarmIDs: liveBridgeIDs)
        }

        // Process next pending disarm if any
        await processPendingDisarmChallenges()
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

        // Lifecycle state (.awaitingWakeCheck) was already persisted by the
        // state machine's `.persist` effect before this session starts.

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

        // Schedule backup alarm at deadline. Deliberately reuses the alarm's
        // own UUID as the AlarmKit ID: the canonical schedule is never active
        // during a wake check, and StopIntent must resolve the backup firing
        // back to this alarm.
        let config = AlarmConfigurationBuilder.makeWakeCheckBackupConfiguration(
            for: alarm,
            deadlineAt: deadlineAt,
            resolvedSettings: settings
        )
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

            let newBridgeIDs = (0..<SchedulingConstants.bridgeWindowSize).map { _ in UUID() }
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

        let bridgeIDs = (0..<SchedulingConstants.bridgeWindowSize).map { _ in UUID() }

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

        // Cancel canonical schedule and enter override phase via the state machine
        await process(event: .overrideActivated(bridgeAlarmIDs: Set(bridgeIDs)), for: alarm.id)

        // Schedule bridge alarms
        guard let parentAlarm = alarms.first(where: { $0.id == alarm.id }) else { return }
        for (i, bridgeID) in bridgeIDs.enumerated() {
            await scheduleBridgeAlarm(
                bridgeID: bridgeID,
                trigger: .fixed(result.bridgeDates[i]),
                parentAlarm: parentAlarm
            )
        }
    }

    private func clearOverrideAndRestore(alarmIndex index: Int) async {
        let alarm = alarms[index]
        let bridgeIDs = Set(alarm.activeOverride?.bridgeAlarmIDs ?? [])

        // The override must be cleared from the model BEFORE processing —
        // scheduleAlarm refuses to register an alarm with an active override.
        alarms[index].activeOverride = nil
        alarms[index].nextTriggerOverrideDate = nil
        alarms[index].isEnabled = true
        alarms[index].snoozeCount = 0
        alarms[index].lifecycleState = .scheduled
        alarms[index].updatedAt = .now
        alarms = sortAlarms(alarms)
        saveAlarms()

        // Cancels bridges and re-registers the canonical schedule.
        await process(event: .overrideRestored(bridgeAlarmIDs: bridgeIDs), for: alarm.id)
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

    private func pendingDisarmAlarmKitID(for alarm: AlarmDefinition, pendingIDs: Set<UUID>) -> UUID {
        if let bridgeID = alarm.activeOverride?.bridgeAlarmIDs.first(where: { pendingIDs.contains($0) }) {
            return bridgeID
        }
        if pendingIDs.contains(alarm.id) {
            return alarm.id
        }
        return alarm.id
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

        // Effects that follow a `.persist` must see the updated alarm (e.g. a
        // reset snooze count when the re-arm configuration is built).
        var effectAlarm = alarm
        for effect in result.effects {
            await executeSideEffect(effect, for: effectAlarm)
            if case .persist(let updated) = effect {
                effectAlarm = updated
            }
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
        let pendingDisarmIDs = persistence.loadPendingDisarmAlarmIDs()

        alarmLoop: for alarm in alarms {
            // Persisted lifecycle state takes priority for post-alerting phases.
            // AlarmKit may still report .alerting briefly after StopIntent runs.
            if alarm.lifecycleState == .awaitingDisarmChallenge {
                runtimePhases[alarm.id] = .awaitingDisarmChallenge(
                    alarmKitID: pendingDisarmAlarmKitID(for: alarm, pendingIDs: pendingDisarmIDs)
                )
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
        sweepStaleBackstops()

        // Restore canonical schedule for any overrides whose restore anchor has passed
        await reconcileOverrides()

        // Process any pending wake-check confirmation UI
        processPendingWakeCheckConfirmations()

        // Process any pending disarm challenges
        await processPendingDisarmChallenges()
    }

    private func reconcileOverrides() async {
        let now = Date.now
        let alarmIDs = alarms.map(\.id)

        for alarmID in alarmIDs {
            guard let index = alarms.firstIndex(where: { $0.id == alarmID }) else { continue }
            let alarm = alarms[index]
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

            // Restore alarm state. The override must be cleared from the model
            // BEFORE processing — scheduleAlarm refuses to register an alarm
            // with an active override.
            alarms[index].activeOverride = nil
            alarms[index].nextTriggerOverrideDate = nil
            if alarm.isSkippingNext {
                alarms[index].isEnabled = true
            }
            alarms[index].lifecycleState = .scheduled
            alarms[index].snoozeCount = 0
            alarms[index].updatedAt = .now
            saveAlarms()

            // Cancels remaining bridges and re-registers the canonical schedule.
            await process(
                event: .overrideRestored(bridgeAlarmIDs: Set(override.bridgeAlarmIDs)),
                for: alarm.id
            )
        }

        alarms = sortAlarms(alarms)
        saveAlarms()
    }

    // cleanupStaleAlarms removed — every alarm that fires goes through
    // StopIntent → pendingDisarm → completeDisarmChallenge → state machine,
    // which handles deletion/re-arm. No cleanup needed on the hot path.

    private func sweepStaleBackstops() {
        let pendingDisarmIDs = persistence.loadPendingDisarmAlarmIDs()

        for (parentID, backstopID) in BackstopSlotStore.allSlots() {
            let parentExists = alarms.contains { $0.id == parentID }
            let hasPendingDisarm = pendingDisarmIDs.contains { pendingID in
                resolveParentAlarm(for: pendingID)?.alarm.id == parentID
            }
            let hasDisarmPresentation = disarmPresentation?.id == parentID
            let hasWakeCheckSession = wakeCheckSessions[parentID] != nil
            let shouldKeep = parentExists && (hasPendingDisarm || hasDisarmPresentation || hasWakeCheckSession)

            guard !shouldKeep else { continue }

            try? alarmManager.stop(id: backstopID)
            try? alarmManager.cancel(id: backstopID)
            if BackstopSlotStore.backstopID(forParent: parentID) == backstopID {
                BackstopSlotStore.clear(forParent: parentID)
            }
            IntentDiagnostics.log("AlarmStore backstop swept parent=\(parentID.uuidString) id=\(backstopID.uuidString)")
        }
    }

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
        guard isInteractivelyVisible else {
            IntentDiagnostics.log("AlarmStore wake-check presentation blocked interactiveVisible=false")
            return
        }

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
            // Schedule showing the UI when checkAt arrives. Cancel any earlier
            // pending presentation so repeated triggers don't stack sleeps.
            let delay = session.checkAt.timeIntervalSinceNow
            pendingWakeCheckUITask?.cancel()
            pendingWakeCheckUITask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0.1, delay)))
                guard !Task.isCancelled else { return }
                self?.processPendingWakeCheckConfirmations()
            }
            return
        }

        wakeUpCheckConfirmationPresentation = WakeUpCheckConfirmationPresentation(id: firstID)
    }

    /// Shows the wake-check confirmation UI if there's an active session
    /// past its checkAt time, even if the user didn't tap the notification.
    private func showWakeCheckConfirmationIfNeeded() {
        guard isInteractivelyVisible else {
            IntentDiagnostics.log("AlarmStore wake-check due presentation blocked interactiveVisible=false")
            return
        }

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
