import AlarmKit
import Foundation
import os

// MARK: - OpenAlarmMetadata

struct OpenAlarmMetadata: AlarmMetadata {
    var source: String
    var isShadowTrial: Bool
    var createdAt: Date

    init(source: String, isShadowTrial: Bool) {
        self.source = source
        self.isShadowTrial = isShadowTrial
        self.createdAt = .now
    }
}

// MARK: - AlarmButton Extensions

extension AlarmButton {
    static var stopButton: Self {
        AlarmButton(text: "Done", textColor: .white, systemImageName: "stop.circle")
    }

    static var snoozeButton: Self {
        AlarmButton(text: "Snooze", textColor: .black, systemImageName: "zzz")
    }
}

// MARK: - Alarm Type Policy

enum AlarmTypePolicy {
    static func normalizeOnWrite(_ alarm: inout UserAlarm) {
        switch alarm.type {
        case .nap, .tryOut:
            alarm.deleteAfterUse = true
        case .regular:
            break
        }
    }
}

// MARK: - Alarm Lifecycle State

enum AlarmLifecycleState: String, Codable, CaseIterable, Sendable {
    case scheduled
    case alerting
    case awaitingDisarmChallenge
    case awaitingWakeCheck
    case completed
}

// MARK: - Alarm Feature Requirement

enum AlarmFeatureRequirement: Hashable, Sendable {
    case notifications
}

// MARK: - Wake-Up Check Timing Policy

public enum WakeUpCheckTimingPolicy {
    public static let debugFiveSecondSentinelMinutes = 0
    public static let defaultCheckDelayMinutes = 5
    public static let defaultResponseTimeoutMinutes = 3
    public static let checkDelayOptionsMinutes: [Int] = [1, 3, 5, 10, 15, 20, 30, 45, 60]
    public static let responseTimeoutOptionsMinutes: [Int] = [1, 2, 3, 5, 10, 20]

    public static func clampCheckDelayMinutes(_ minutes: Int) -> Int {
        if minutes == debugFiveSecondSentinelMinutes {
            return debugFiveSecondSentinelMinutes
        }
        return min(60, max(1, minutes))
    }

    public static func normalizeResponseTimeoutMinutes(_ minutes: Int) -> Int {
        if minutes == debugFiveSecondSentinelMinutes {
            return debugFiveSecondSentinelMinutes
        }
        return max(1, minutes)
    }

    public static func checkDelayInterval(for minutes: Int) -> TimeInterval {
        let normalizedMinutes = clampCheckDelayMinutes(minutes)
        if normalizedMinutes == debugFiveSecondSentinelMinutes {
            return 5
        }
        return TimeInterval(normalizedMinutes * 60)
    }

    public static func responseTimeoutInterval(for minutes: Int) -> TimeInterval {
        let normalizedMinutes = normalizeResponseTimeoutMinutes(minutes)
        if normalizedMinutes == debugFiveSecondSentinelMinutes {
            return 5
        }
        return TimeInterval(normalizedMinutes * 60)
    }
}

// MARK: - Disarm Tasks

enum MathDifficulty: String, Codable, CaseIterable, Sendable {
    case simple
    case hard
}

enum AlarmTask: Codable, Equatable, Sendable {
    case dummy
    case math(difficulty: MathDifficulty, count: Int)

    var displayName: String {
        switch self {
        case .dummy: String(localized: "task_dummy_name")
        case .math: String(localized: "task_math_name")
        }
    }
}

// MARK: - AlarmVolumeSettings

struct AlarmVolumeSettings: Codable, Equatable, Sendable {
    var targetPercent: Int

    static let `default` = AlarmVolumeSettings(targetPercent: 20)

    init(targetPercent: Int = 20) {
        self.targetPercent = Self.clamp(targetPercent)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetPercent = Self.clamp(try container.decodeIfPresent(Int.self, forKey: .targetPercent) ?? Self.default.targetPercent)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetPercent, forKey: .targetPercent)
    }

    private enum CodingKeys: String, CodingKey {
        case targetPercent
    }

    static func clamp(_ percent: Int) -> Int {
        min(100, max(0, percent))
    }

    var targetScalar: Float {
        Float(targetPercent) / 100
    }
}

// MARK: - SharedAlarmSettings

struct SharedAlarmSettings: Codable, Equatable, Sendable {
    var snoozeEnabled: Bool
    var snoozeDurationMinutes: Int
    var maxSnoozes: Int?
    var wakeUpCheckEnabled: Bool
    var wakeUpCheckDelayMinutes: Int
    var wakeUpCheckResponseTimeoutMinutes: Int
    var tasks: [AlarmTask]
    var volume: AlarmVolumeSettings

    static let featureDefaults = SharedAlarmSettings(
        snoozeEnabled: false,
        snoozeDurationMinutes: 5,
        maxSnoozes: 3,
        wakeUpCheckEnabled: false,
        wakeUpCheckDelayMinutes: WakeUpCheckTimingPolicy.defaultCheckDelayMinutes,
        wakeUpCheckResponseTimeoutMinutes: WakeUpCheckTimingPolicy.defaultResponseTimeoutMinutes,
        tasks: [],
        volume: .default
    )

    func canSnoozeAgain(currentCount: Int) -> Bool {
        guard snoozeEnabled else {
            return false
        }

        guard let maxSnoozes else {
            return true
        }

        return currentCount < maxSnoozes
    }

    var featureRequirements: Set<AlarmFeatureRequirement> {
        var requirements = Set<AlarmFeatureRequirement>()

        if wakeUpCheckEnabled {
            requirements.insert(.notifications)
        }

        return requirements
    }

    func hasFeatureRequirement(_ requirement: AlarmFeatureRequirement) -> Bool {
        featureRequirements.contains(requirement)
    }

    private enum CodingKeys: String, CodingKey {
        case snoozeEnabled
        case snoozeDurationMinutes
        case maxSnoozes
        case wakeUpCheckEnabled
        case wakeUpCheckDelayMinutes
        case wakeUpCheckResponseTimeoutMinutes
        case tasks
        case volume
    }

    init(
        snoozeEnabled: Bool,
        snoozeDurationMinutes: Int,
        maxSnoozes: Int?,
        wakeUpCheckEnabled: Bool,
        wakeUpCheckDelayMinutes: Int,
        wakeUpCheckResponseTimeoutMinutes: Int,
        tasks: [AlarmTask] = [],
        volume: AlarmVolumeSettings = .default
    ) {
        self.snoozeEnabled = snoozeEnabled
        self.snoozeDurationMinutes = snoozeDurationMinutes
        self.maxSnoozes = maxSnoozes
        self.wakeUpCheckEnabled = wakeUpCheckEnabled
        self.wakeUpCheckDelayMinutes = WakeUpCheckTimingPolicy.clampCheckDelayMinutes(wakeUpCheckDelayMinutes)
        self.wakeUpCheckResponseTimeoutMinutes = WakeUpCheckTimingPolicy.normalizeResponseTimeoutMinutes(wakeUpCheckResponseTimeoutMinutes)
        self.tasks = tasks
        self.volume = volume
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snoozeEnabled = try container.decodeIfPresent(Bool.self, forKey: .snoozeEnabled) ?? SharedAlarmSettings.featureDefaults.snoozeEnabled
        snoozeDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .snoozeDurationMinutes) ?? SharedAlarmSettings.featureDefaults.snoozeDurationMinutes
        maxSnoozes = try container.decodeIfPresent(Int.self, forKey: .maxSnoozes) ?? SharedAlarmSettings.featureDefaults.maxSnoozes
        wakeUpCheckEnabled = try container.decodeIfPresent(Bool.self, forKey: .wakeUpCheckEnabled) ?? SharedAlarmSettings.featureDefaults.wakeUpCheckEnabled
        wakeUpCheckDelayMinutes = WakeUpCheckTimingPolicy.clampCheckDelayMinutes(
            try container.decodeIfPresent(Int.self, forKey: .wakeUpCheckDelayMinutes) ?? SharedAlarmSettings.featureDefaults.wakeUpCheckDelayMinutes
        )
        wakeUpCheckResponseTimeoutMinutes = WakeUpCheckTimingPolicy.normalizeResponseTimeoutMinutes(
            try container.decodeIfPresent(Int.self, forKey: .wakeUpCheckResponseTimeoutMinutes) ?? SharedAlarmSettings.featureDefaults.wakeUpCheckResponseTimeoutMinutes
        )
        tasks = try container.decodeIfPresent([AlarmTask].self, forKey: .tasks) ?? []
        volume = try container.decodeIfPresent(AlarmVolumeSettings.self, forKey: .volume) ?? .default
    }
}

// MARK: - AlarmDefinition + AlarmKit Schedule

extension AlarmDefinition {
    var schedule: Alarm.Schedule {
        let time = Alarm.Schedule.Relative.Time(hour: hour, minute: minute)
        if repeatDays.isEmpty {
            return .relative(.init(time: time, repeats: .never))
        }

        return .relative(.init(
            time: time,
            repeats: .weekly(sortedRepeatDays.map(\.localeWeekday))
        ))
    }
}

// MARK: - AlarmScheduleResolver

enum AlarmScheduleResolver {
    static func runtimeSchedule(for alarm: UserAlarm) -> Alarm.Schedule {
        switch alarm.type {
        case .nap, .tryOut:
            if let fixedDate = alarm.fixedTriggerDate {
                return .fixed(fixedDate)
            }
            return alarm.schedule
        case .regular:
            return alarm.schedule
        }
    }
}

// MARK: - NapDraft

struct NapDraft: Equatable {
    var durationHours: Int
    var durationMinutes: Int
    var settingsMode: SettingsMode

    /// Cached default settings for pre-filling when user toggles to custom.
    private var cachedDefaults: SharedAlarmSettings

    var useDefaultSharedSettings: Bool {
        get {
            if case .useDefault = settingsMode { return true }
            return false
        }
        set {
            if newValue {
                settingsMode = .useDefault
            } else {
                settingsMode = .custom(cachedDefaults)
            }
        }
    }

    var customSharedSettings: SharedAlarmSettings {
        get {
            if case .custom(let settings) = settingsMode { return settings }
            return cachedDefaults
        }
        set {
            settingsMode = .custom(newValue)
        }
    }

    init(
        totalMinutes: Int,
        useDefaultSharedSettings: Bool = true,
        customSharedSettings: SharedAlarmSettings
    ) {
        let clampedMinutes = max(0, totalMinutes)
        durationHours = clampedMinutes / 60
        durationMinutes = clampedMinutes % 60
        self.cachedDefaults = customSharedSettings
        if useDefaultSharedSettings {
            self.settingsMode = .useDefault
        } else {
            self.settingsMode = .custom(customSharedSettings)
        }
    }

    var totalMinutes: Int {
        // 0 is valid (5-second testing mode nap)
        max(0, durationHours * 60 + durationMinutes)
    }

    mutating func applyDefaultSharedSettings(_ defaults: SharedAlarmSettings) {
        cachedDefaults = defaults
    }

    func resolvedSharedSettings(defaults: SharedAlarmSettings) -> SharedAlarmSettings {
        useDefaultSharedSettings ? defaults : customSharedSettings
    }
}

// MARK: - AlarmDraft

struct AlarmDraft: Equatable {
    var name: String
    var time: Date
    var repeatDays: Set<AlarmWeekday>
    var deleteAfterUse: Bool
    var settingsMode: SettingsMode

    /// Cached default settings for pre-filling when user toggles to custom.
    private var cachedDefaults: SharedAlarmSettings

    var useDefaultSharedSettings: Bool {
        get {
            if case .useDefault = settingsMode { return true }
            return false
        }
        set {
            if newValue {
                settingsMode = .useDefault
            } else {
                settingsMode = .custom(cachedDefaults)
            }
        }
    }

    var customSharedSettings: SharedAlarmSettings {
        get {
            if case .custom(let settings) = settingsMode { return settings }
            return cachedDefaults
        }
        set {
            settingsMode = .custom(newValue)
        }
    }

    init(
        name: String = "",
        time: Date = .now,
        repeatDays: Set<AlarmWeekday> = [],
        deleteAfterUse: Bool = true,
        useDefaultSharedSettings: Bool = true,
        customSharedSettings: SharedAlarmSettings = .featureDefaults
    ) {
        self.name = name
        self.time = time
        self.repeatDays = repeatDays
        self.deleteAfterUse = deleteAfterUse
        self.cachedDefaults = customSharedSettings
        if useDefaultSharedSettings {
            self.settingsMode = .useDefault
        } else {
            self.settingsMode = .custom(customSharedSettings)
        }
    }

    init(alarm: UserAlarm) {
        self.name = alarm.name
        self.time = alarm.triggerDateForDisplay
        self.repeatDays = Set(alarm.repeatDays)
        self.deleteAfterUse = alarm.deleteAfterUse
        self.settingsMode = alarm.settingsMode
        if case .custom(let settings) = alarm.settingsMode {
            self.cachedDefaults = settings
        } else {
            self.cachedDefaults = .featureDefaults
        }
    }

    mutating func toggleRepeatDay(_ day: AlarmWeekday) {
        if repeatDays.contains(day) {
            repeatDays.remove(day)
        } else {
            repeatDays.insert(day)
        }

        if !repeatDays.isEmpty {
            deleteAfterUse = false
        }
    }

    mutating func setDeleteAfterUse(_ value: Bool) {
        deleteAfterUse = value
        if value {
            repeatDays.removeAll()
        }
    }

    mutating func applyDefaultSharedSettings(_ defaults: SharedAlarmSettings) {
        cachedDefaults = defaults
    }

    func resolvedSharedSettings(defaults: SharedAlarmSettings) -> SharedAlarmSettings {
        useDefaultSharedSettings ? defaults : customSharedSettings
    }

    func toUserAlarm(
        id: UUID = UUID(),
        existingCreatedAt: Date? = nil,
        defaultSharedSettings: SharedAlarmSettings,
        alarmType: AlarmType = .regular
    ) -> UserAlarm {
        let timeComponents = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: time)
        let hour = timeComponents.hour ?? 7
        let minute = timeComponents.minute ?? 0

        let resolvedSettingsMode: SettingsMode = settingsMode

        let daysArray = Array(repeatDays)
        let alarmRecurrence: AlarmRecurrence = daysArray.isEmpty ? .none : .weekly(daysArray)

        return UserAlarm(
            id: id,
            name: name,
            trigger: .time(hour: hour, minute: minute),
            recurrence: alarmRecurrence,
            type: alarmType,
            deleteAfterUse: deleteAfterUse,
            settingsMode: resolvedSettingsMode,
            nextTriggerOverrideDate: nil,
            isEnabled: true,
            activeOverride: nil,
            snoozeCount: 0,
            lifecycleState: .scheduled,
            createdAt: existingCreatedAt ?? .now,
            updatedAt: .now
        )
    }
}

// MARK: - AlarmWeekday repeat summary

extension Collection where Element == AlarmWeekday {
    func repeatSummary() -> String {
        let sorted = self.sorted { $0.rawValue < $1.rawValue }
        return sorted
            .map { $0.veryShortSymbol() }
            .joined(separator: " ")
    }
}

// MARK: - WakeUpCheckConfirmationPresentation

struct WakeUpCheckConfirmationPresentation: Identifiable {
    let id: UUID
}

// MARK: - NotificationPermissionStatus

enum NotificationPermissionStatus: Equatable {
    case notDetermined
    case denied
    case authorized
}

// MARK: - WakeUpCheckNotificationConstants

enum WakeUpCheckNotificationConstants {
    static let categoryID = "OPENALARM_WAKE_CHECK"
    static let alarmIDUserInfoKey = "alarmID"
    static let cycleUserInfoKey = "cycle"

    static func notificationID(alarmID: UUID, cycle: Int) -> String {
        "wakecheck.\(alarmID.uuidString).\(cycle)"
    }
}

// MARK: - WakeUpCheckAction

enum WakeUpCheckAction: String {
    case confirmAwake = "WAKE_CHECK_CONFIRM_AWAKE"
}

// MARK: - WakeCheckSession

struct WakeCheckSession: Codable, Equatable, Sendable {
    var alarmID: UUID
    var cycle: Int
    var checkAt: Date
    var deadlineAt: Date
    var notificationID: String
}

// MARK: - AlarmStoreError

enum AlarmStoreError: Error {
    case permissionDenied
    case scheduleFailed
}

// MARK: - Notification.Name

extension Notification.Name {
    static let wakeUpCheckConfirmationRequested = Notification.Name("wakeUpCheckConfirmationRequested")
    static let disarmChallengeRequested = Notification.Name("disarmChallengeRequested")
}

// MARK: - WakeUpCheckNotificationService

import UserNotifications

@MainActor
final class WakeUpCheckNotificationService {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func scheduleWakeCheckNotification(
        alarmID: UUID,
        cycle: Int,
        triggerDate: Date
    ) async {
        let notificationID = WakeUpCheckNotificationConstants.notificationID(alarmID: alarmID, cycle: cycle)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "wake_check_notification_title")
        content.body = String(localized: "wake_check_notification_body")
        content.sound = .default
        content.categoryIdentifier = WakeUpCheckNotificationConstants.categoryID
        content.userInfo = [
            WakeUpCheckNotificationConstants.alarmIDUserInfoKey: alarmID.uuidString,
            WakeUpCheckNotificationConstants.cycleUserInfoKey: cycle,
        ]

        let delay = max(1, triggerDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: trigger)

        do {
            try await center.add(request)
        } catch {
            // Best-effort; if notification scheduling fails the backup alarm will still fire
        }
    }

    func cancelNotification(id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    func ensureCategoryRegistered() {
        let confirmAction = UNNotificationAction(
            identifier: WakeUpCheckAction.confirmAwake.rawValue,
            title: String(localized: "wake_check_notification_action_awake"),
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: WakeUpCheckNotificationConstants.categoryID,
            actions: [confirmAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([category])
    }
}

// MARK: - AlarmPersistence (legacy, kept for notification delegate and StopIntent)

final class AlarmPersistence: Sendable {
    private static let logger = Logger(subsystem: "com.openalarm", category: "AlarmPersistence")
    private static let appGroupMigrationKey = "OPENALARM_APP_GROUP_STORE_MIGRATED_V1"

    static let shared = AlarmPersistence(defaults: OpenAlarmSharedDefaults.userDefaults)

    private nonisolated(unsafe) let defaults: UserDefaults

    private let userAlarmsKey = "OPENALARM_USER_ALARMS_V1"
    private let defaultSharedSettingsKey = "OPENALARM_DEFAULT_SHARED_SETTINGS_V1"
    private let testingModeEnabledKey = "OPENALARM_TESTING_MODE_ENABLED_V1"
    private let napDefaultSharedSettingsKey = "OPENALARM_NAP_DEFAULT_SHARED_SETTINGS_V1"
    private let defaultNapDurationMinutesKey = "OPENALARM_DEFAULT_NAP_DURATION_MINUTES_V1"
    private let liveActivitiesEnabledKey = "OPENALARM_LIVE_ACTIVITIES_ENABLED_V1"
    private let pendingWakeUpCheckShowConfirmUIIDsKey = "OPENALARM_PENDING_WAKE_CHECK_SHOW_CONFIRM_UI_IDS_V1"
    private let wakeCheckSessionsKey = "OPENALARM_WAKE_CHECK_SESSIONS_V1"
    private let pendingDisarmAlarmIDsKey = "OPENALARM_PENDING_DISARM_ALARM_IDS_V1"
    init(defaults: UserDefaults = OpenAlarmSharedDefaults.userDefaults) {
        self.defaults = defaults
    }

    static func migrateStandardStoreIfNeeded() {
        let sharedDefaults = OpenAlarmSharedDefaults.userDefaults
        let standardDefaults = UserDefaults.standard

        guard sharedDefaults !== standardDefaults else {
            return
        }

        guard !sharedDefaults.bool(forKey: appGroupMigrationKey) else {
            return
        }

        let keysToMigrate = [
            "OPENALARM_USER_ALARMS_V1",
            "OPENALARM_DEFAULT_SHARED_SETTINGS_V1",
            "OPENALARM_TESTING_MODE_ENABLED_V1",
            "OPENALARM_NAP_DEFAULT_SHARED_SETTINGS_V1",
            "OPENALARM_DEFAULT_NAP_DURATION_MINUTES_V1",
            "OPENALARM_LIVE_ACTIVITIES_ENABLED_V1",
            "OPENALARM_PENDING_WAKE_CHECK_SHOW_CONFIRM_UI_IDS_V1",
            "OPENALARM_WAKE_CHECK_SESSIONS_V1",
            "OPENALARM_PENDING_DISARM_ALARM_IDS_V1",
            "OPENALARM_FORCE_CLOSE_ALARM_ID",
            "OPENALARM_WAKE_CHECK_GRACE_APPLIED_IDS"
        ]

        for key in keysToMigrate where sharedDefaults.object(forKey: key) == nil {
            if let value = standardDefaults.object(forKey: key) {
                sharedDefaults.set(value, forKey: key)
            }
        }

        sharedDefaults.set(true, forKey: appGroupMigrationKey)
    }

    // MARK: - User Alarms

    func loadUserAlarms() -> [UserAlarm] {
        guard let data = defaults.data(forKey: userAlarmsKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([UserAlarm].self, from: data)
        } catch {
            return []
        }
    }

    func saveUserAlarms(_ alarms: [UserAlarm]) {
        do {
            let data = try JSONEncoder().encode(alarms)
            defaults.set(data, forKey: userAlarmsKey)
        } catch {
            defaults.removeObject(forKey: userAlarmsKey)
        }
    }

    // MARK: - Default Shared Settings

    func loadDefaultSharedSettings() -> SharedAlarmSettings {
        guard let data = defaults.data(forKey: defaultSharedSettingsKey) else {
            return .featureDefaults
        }

        do {
            return try JSONDecoder().decode(SharedAlarmSettings.self, from: data)
        } catch {
            return .featureDefaults
        }
    }

    func saveDefaultSharedSettings(_ settings: SharedAlarmSettings) {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: defaultSharedSettingsKey)
        } catch {
            defaults.removeObject(forKey: defaultSharedSettingsKey)
        }
    }

    // MARK: - Testing Mode

    func loadTestingModeEnabled() -> Bool {
        defaults.bool(forKey: testingModeEnabledKey)
    }

    func saveTestingModeEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: testingModeEnabledKey)
    }

    // MARK: - Nap Default Shared Settings

    func loadNapDefaultSharedSettings() -> SharedAlarmSettings? {
        guard let data = defaults.data(forKey: napDefaultSharedSettingsKey) else { return nil }
        do {
            return try JSONDecoder().decode(SharedAlarmSettings.self, from: data)
        } catch {
            Self.logger.error("Failed to decode nap default settings: \(error.localizedDescription)")
            return nil
        }
    }

    func saveNapDefaultSharedSettings(_ settings: SharedAlarmSettings?) {
        if let settings {
            do {
                let data = try JSONEncoder().encode(settings)
                defaults.set(data, forKey: napDefaultSharedSettingsKey)
            } catch {
                Self.logger.error("Failed to encode nap default settings: \(error.localizedDescription)")
            }
        } else {
            defaults.removeObject(forKey: napDefaultSharedSettingsKey)
        }
    }

    // MARK: - Default Nap Duration

    func loadDefaultNapDurationMinutes() -> Int {
        // 0 is a valid sentinel for 5-second testing mode naps
        if defaults.object(forKey: defaultNapDurationMinutesKey) == nil {
            return 35
        }
        return defaults.integer(forKey: defaultNapDurationMinutesKey)
    }

    func saveDefaultNapDurationMinutes(_ minutes: Int) {
        defaults.set(max(0, minutes), forKey: defaultNapDurationMinutesKey)
    }

    // MARK: - Live Activity Settings

    func loadLiveActivitiesEnabled() -> Bool {
        if defaults.object(forKey: liveActivitiesEnabledKey) == nil {
            return true
        }
        return defaults.bool(forKey: liveActivitiesEnabledKey)
    }

    func saveLiveActivitiesEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: liveActivitiesEnabledKey)
    }

    // MARK: - Pending Wake-Up Check Show Confirm UI IDs

    func loadPendingWakeUpCheckShowConfirmUIIDs() -> Set<UUID> {
        loadUUIDSet(forKey: pendingWakeUpCheckShowConfirmUIIDsKey)
    }

    func savePendingWakeUpCheckShowConfirmUIIDs(_ ids: Set<UUID>) {
        saveUUIDSet(ids, forKey: pendingWakeUpCheckShowConfirmUIIDsKey)
    }

    // MARK: - Wake Check Sessions

    func loadWakeCheckSessions() -> [UUID: WakeCheckSession] {
        guard let data = defaults.data(forKey: wakeCheckSessionsKey) else { return [:] }
        do {
            let sessions = try JSONDecoder().decode([WakeCheckSession].self, from: data)
            return Dictionary(uniqueKeysWithValues: sessions.map { ($0.alarmID, $0) })
        } catch {
            Self.logger.error("Failed to decode wake check sessions: \(error.localizedDescription)")
            return [:]
        }
    }

    func saveWakeCheckSessions(_ sessions: [UUID: WakeCheckSession]) {
        do {
            let array = Array(sessions.values)
            let data = try JSONEncoder().encode(array)
            defaults.set(data, forKey: wakeCheckSessionsKey)
        } catch {
            Self.logger.error("Failed to encode wake check sessions: \(error.localizedDescription)")
        }
    }

    // MARK: - Pending Disarm Alarm IDs

    func loadPendingDisarmAlarmIDs() -> Set<UUID> {
        loadUUIDSet(forKey: pendingDisarmAlarmIDsKey)
    }

    func savePendingDisarmAlarmIDs(_ ids: Set<UUID>) {
        saveUUIDSet(ids, forKey: pendingDisarmAlarmIDsKey)
    }

    // MARK: - Private helpers

    private func loadUUIDSet(forKey key: String) -> Set<UUID> {
        guard let raw = defaults.array(forKey: key) as? [String] else {
            return []
        }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private func saveUUIDSet(_ ids: Set<UUID>, forKey key: String) {
        let raw = ids.map(\.uuidString)
        defaults.set(raw, forKey: key)
    }
}
