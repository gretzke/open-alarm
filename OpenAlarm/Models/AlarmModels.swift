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

// MARK: - Alarm Type

enum AlarmType: String, Codable, CaseIterable, Sendable {
    case regular
    case nap
    case tryOut
}

// MARK: - Alarm Type Policy

enum AlarmTypePolicy {
    static func normalizeOnWrite(_ alarm: inout UserAlarm) {
        switch alarm.alarmType {
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

// MARK: - SharedAlarmSettings

struct SharedAlarmSettings: Codable, Equatable, Sendable {
    var snoozeEnabled: Bool
    var snoozeDurationMinutes: Int
    var maxSnoozes: Int?
    var wakeUpCheckEnabled: Bool
    var wakeUpCheckDelayMinutes: Int
    var wakeUpCheckResponseTimeoutMinutes: Int

    static let featureDefaults = SharedAlarmSettings(
        snoozeEnabled: false,
        snoozeDurationMinutes: 5,
        maxSnoozes: 3,
        wakeUpCheckEnabled: false,
        wakeUpCheckDelayMinutes: WakeUpCheckTimingPolicy.defaultCheckDelayMinutes,
        wakeUpCheckResponseTimeoutMinutes: WakeUpCheckTimingPolicy.defaultResponseTimeoutMinutes
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
    }

    init(
        snoozeEnabled: Bool,
        snoozeDurationMinutes: Int,
        maxSnoozes: Int?,
        wakeUpCheckEnabled: Bool,
        wakeUpCheckDelayMinutes: Int,
        wakeUpCheckResponseTimeoutMinutes: Int
    ) {
        self.snoozeEnabled = snoozeEnabled
        self.snoozeDurationMinutes = snoozeDurationMinutes
        self.maxSnoozes = maxSnoozes
        self.wakeUpCheckEnabled = wakeUpCheckEnabled
        self.wakeUpCheckDelayMinutes = WakeUpCheckTimingPolicy.clampCheckDelayMinutes(wakeUpCheckDelayMinutes)
        self.wakeUpCheckResponseTimeoutMinutes = WakeUpCheckTimingPolicy.normalizeResponseTimeoutMinutes(wakeUpCheckResponseTimeoutMinutes)
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
    }
}

// MARK: - UserAlarm

struct UserAlarm: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var hour: Int
    var minute: Int
    var repeatDays: [AlarmWeekday]
    var deleteAfterUse: Bool
    var alarmType: AlarmType
    var fixedTriggerDate: Date?
    var durationMinutes: Int?
    var pausedRemainingSeconds: TimeInterval?

    var useDefaultSharedSettings: Bool
    var customSharedSettings: SharedAlarmSettings

    var nextTriggerOverrideDate: Date?

    var isEnabled: Bool

    var skipNextUntilDate: Date?

    var snoozeCount: Int

    var lifecycleState: AlarmLifecycleState
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        name: String,
        hour: Int,
        minute: Int,
        repeatDays: [AlarmWeekday],
        deleteAfterUse: Bool,
        alarmType: AlarmType = .regular,
        fixedTriggerDate: Date? = nil,
        durationMinutes: Int? = nil,
        pausedRemainingSeconds: TimeInterval? = nil,
        useDefaultSharedSettings: Bool,
        customSharedSettings: SharedAlarmSettings,
        nextTriggerOverrideDate: Date?,
        isEnabled: Bool,
        skipNextUntilDate: Date?,
        snoozeCount: Int,
        lifecycleState: AlarmLifecycleState,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hour = hour
        self.minute = minute
        self.repeatDays = repeatDays.sorted { $0.rawValue < $1.rawValue }
        self.deleteAfterUse = deleteAfterUse
        self.alarmType = alarmType
        self.fixedTriggerDate = fixedTriggerDate
        self.durationMinutes = durationMinutes
        self.pausedRemainingSeconds = pausedRemainingSeconds
        self.useDefaultSharedSettings = useDefaultSharedSettings
        self.customSharedSettings = customSharedSettings
        self.nextTriggerOverrideDate = nextTriggerOverrideDate
        self.isEnabled = isEnabled
        self.skipNextUntilDate = skipNextUntilDate
        self.snoozeCount = snoozeCount
        self.lifecycleState = lifecycleState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isRepeating: Bool {
        !repeatDays.isEmpty
    }

    var isSkippingNext: Bool {
        !isEnabled && skipNextUntilDate != nil
    }

    var isFullyDisabled: Bool {
        !isEnabled && skipNextUntilDate == nil
    }

    var isNap: Bool { alarmType == .nap }
    var isTryOut: Bool { alarmType == .tryOut }
    var isPaused: Bool { pausedRemainingSeconds != nil }

    func remainingSeconds(referenceDate: Date = .now) -> TimeInterval {
        if let pausedRemainingSeconds {
            return max(0, pausedRemainingSeconds)
        }
        guard let target = fixedTriggerDate else { return 0 }
        return max(0, target.timeIntervalSince(referenceDate))
    }

    static func makeNap(
        from draft: NapDraft,
        defaultSharedSettings: SharedAlarmSettings,
        targetDate: Date,
        now: Date = .now
    ) -> UserAlarm {
        let customSettings = draft.useDefaultSharedSettings ? defaultSharedSettings : draft.customSharedSettings
        let id = UUID()
        var alarm = UserAlarm(
            id: id,
            name: "",
            hour: 0,
            minute: 0,
            repeatDays: [],
            deleteAfterUse: true,
            alarmType: .nap,
            fixedTriggerDate: targetDate,
            durationMinutes: draft.totalMinutes,
            pausedRemainingSeconds: nil,
            useDefaultSharedSettings: draft.useDefaultSharedSettings,
            customSharedSettings: customSettings,
            nextTriggerOverrideDate: nil,
            isEnabled: true,
            skipNextUntilDate: nil,
            snoozeCount: 0,
            lifecycleState: .scheduled,
            createdAt: now,
            updatedAt: now
        )
        AlarmTypePolicy.normalizeOnWrite(&alarm)
        return alarm
    }

    var triggerDateForDisplay: Date {
        if let nextTriggerOverrideDate {
            return nextTriggerOverrideDate
        }

        var components = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: .now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return Calendar.autoupdatingCurrent.date(from: components) ?? .now
    }

    var sortedRepeatDays: [AlarmWeekday] {
        repeatDays.sorted { $0.rawValue < $1.rawValue }
    }

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

    func resolvedSharedSettings(defaults: SharedAlarmSettings) -> SharedAlarmSettings {
        useDefaultSharedSettings ? defaults : customSharedSettings
    }

    func canSnoozeAgain(defaults: SharedAlarmSettings) -> Bool {
        resolvedSharedSettings(defaults: defaults).canSnoozeAgain(currentCount: snoozeCount)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case hour
        case minute
        case repeatDays
        case deleteAfterUse
        case alarmType
        case fixedTriggerDate
        case durationMinutes
        case pausedRemainingSeconds
        case wakeUpCheckEnabled
        case wakeUpCheckDelayMinutes
        case useDefaultSharedSettings
        case customSharedSettings
        case nextTriggerOverrideDate
        case isEnabled
        case skipNextUntilDate
        case snoozeCount
        case lifecycleState
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = (try container.decodeIfPresent(String.self, forKey: .name) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        hour = try container.decode(Int.self, forKey: .hour)
        minute = try container.decode(Int.self, forKey: .minute)
        repeatDays = (try container.decodeIfPresent([AlarmWeekday].self, forKey: .repeatDays) ?? [])
            .sorted { $0.rawValue < $1.rawValue }
        deleteAfterUse = try container.decodeIfPresent(Bool.self, forKey: .deleteAfterUse) ?? true
        alarmType = try container.decodeIfPresent(AlarmType.self, forKey: .alarmType) ?? .regular
        fixedTriggerDate = try container.decodeIfPresent(Date.self, forKey: .fixedTriggerDate)
        durationMinutes = try container.decodeIfPresent(Int.self, forKey: .durationMinutes)
        pausedRemainingSeconds = try container.decodeIfPresent(Double.self, forKey: .pausedRemainingSeconds)

        customSharedSettings = try container.decodeIfPresent(SharedAlarmSettings.self, forKey: .customSharedSettings) ?? .featureDefaults
        useDefaultSharedSettings = try container.decodeIfPresent(Bool.self, forKey: .useDefaultSharedSettings) ?? true

        if let legacyWakeEnabled = try container.decodeIfPresent(Bool.self, forKey: .wakeUpCheckEnabled) {
            customSharedSettings.wakeUpCheckEnabled = legacyWakeEnabled
        }
        if let legacyWakeDelay = try container.decodeIfPresent(Int.self, forKey: .wakeUpCheckDelayMinutes) {
            customSharedSettings.wakeUpCheckDelayMinutes = WakeUpCheckTimingPolicy.clampCheckDelayMinutes(legacyWakeDelay)
        }

        nextTriggerOverrideDate = try container.decodeIfPresent(Date.self, forKey: .nextTriggerOverrideDate)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        skipNextUntilDate = try container.decodeIfPresent(Date.self, forKey: .skipNextUntilDate)

        snoozeCount = try container.decodeIfPresent(Int.self, forKey: .snoozeCount) ?? 0

        lifecycleState = try container.decodeIfPresent(AlarmLifecycleState.self, forKey: .lifecycleState) ?? .scheduled
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(hour, forKey: .hour)
        try container.encode(minute, forKey: .minute)
        try container.encode(repeatDays, forKey: .repeatDays)
        try container.encode(deleteAfterUse, forKey: .deleteAfterUse)
        try container.encode(alarmType, forKey: .alarmType)
        try container.encodeIfPresent(fixedTriggerDate, forKey: .fixedTriggerDate)
        try container.encodeIfPresent(durationMinutes, forKey: .durationMinutes)
        try container.encodeIfPresent(pausedRemainingSeconds, forKey: .pausedRemainingSeconds)
        try container.encode(useDefaultSharedSettings, forKey: .useDefaultSharedSettings)
        try container.encode(customSharedSettings, forKey: .customSharedSettings)
        try container.encodeIfPresent(nextTriggerOverrideDate, forKey: .nextTriggerOverrideDate)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(skipNextUntilDate, forKey: .skipNextUntilDate)
        try container.encode(snoozeCount, forKey: .snoozeCount)
        try container.encode(lifecycleState, forKey: .lifecycleState)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

// MARK: - AlarmScheduleResolver

enum AlarmScheduleResolver {
    static func runtimeSchedule(for alarm: UserAlarm) -> Alarm.Schedule {
        switch alarm.alarmType {
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
    var useDefaultSharedSettings: Bool
    var customSharedSettings: SharedAlarmSettings

    init(
        totalMinutes: Int,
        useDefaultSharedSettings: Bool = true,
        customSharedSettings: SharedAlarmSettings
    ) {
        let clampedMinutes = max(1, totalMinutes)
        durationHours = clampedMinutes / 60
        durationMinutes = clampedMinutes % 60
        self.useDefaultSharedSettings = useDefaultSharedSettings
        self.customSharedSettings = customSharedSettings
    }

    var totalMinutes: Int {
        max(1, durationHours * 60 + durationMinutes)
    }

    mutating func applyDefaultSharedSettings(_ defaults: SharedAlarmSettings) {
        customSharedSettings = defaults
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

    var useDefaultSharedSettings: Bool
    var customSharedSettings: SharedAlarmSettings

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
        self.useDefaultSharedSettings = useDefaultSharedSettings
        self.customSharedSettings = customSharedSettings
    }

    init(alarm: UserAlarm) {
        self.name = alarm.name
        self.time = alarm.triggerDateForDisplay
        self.repeatDays = Set(alarm.repeatDays)
        self.deleteAfterUse = alarm.deleteAfterUse
        self.useDefaultSharedSettings = alarm.useDefaultSharedSettings
        self.customSharedSettings = alarm.customSharedSettings
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
        customSharedSettings = defaults
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
        let persistedCustomSharedSettings = useDefaultSharedSettings ? defaultSharedSettings : customSharedSettings

        return UserAlarm(
            id: id,
            name: name,
            hour: hour,
            minute: minute,
            repeatDays: Array(repeatDays),
            deleteAfterUse: deleteAfterUse,
            alarmType: alarmType,
            useDefaultSharedSettings: useDefaultSharedSettings,
            customSharedSettings: persistedCustomSharedSettings,
            nextTriggerOverrideDate: nil,
            isEnabled: true,
            skipNextUntilDate: nil,
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

// MARK: - AlarmStoreError

enum AlarmStoreError: Error {
    case permissionDenied
    case scheduleFailed
}

// MARK: - Notification.Name

extension Notification.Name {
    static let wakeUpCheckConfirmationRequested = Notification.Name("wakeUpCheckConfirmationRequested")
}

// MARK: - WakeUpCheckNotificationService

import UserNotifications

@MainActor
final class WakeUpCheckNotificationService {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
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

    static let shared = AlarmPersistence()

    private nonisolated(unsafe) let defaults: UserDefaults

    private let userAlarmsKey = "OPENALARM_USER_ALARMS_V1"
    private let defaultSharedSettingsKey = "OPENALARM_DEFAULT_SHARED_SETTINGS_V1"
    private let testingModeEnabledKey = "OPENALARM_TESTING_MODE_ENABLED_V1"
    private let napDefaultSharedSettingsKey = "OPENALARM_NAP_DEFAULT_SHARED_SETTINGS_V1"
    private let defaultNapDurationMinutesKey = "OPENALARM_DEFAULT_NAP_DURATION_MINUTES_V1"
    private let pendingWakeUpCheckShowConfirmUIIDsKey = "OPENALARM_PENDING_WAKE_CHECK_SHOW_CONFIRM_UI_IDS_V1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        let raw = defaults.integer(forKey: defaultNapDurationMinutesKey)
        return raw > 0 ? raw : 35
    }

    func saveDefaultNapDurationMinutes(_ minutes: Int) {
        defaults.set(max(1, minutes), forKey: defaultNapDurationMinutesKey)
    }

    // MARK: - Pending Wake-Up Check Show Confirm UI IDs

    func loadPendingWakeUpCheckShowConfirmUIIDs() -> Set<UUID> {
        loadUUIDSet(forKey: pendingWakeUpCheckShowConfirmUIIDsKey)
    }

    func savePendingWakeUpCheckShowConfirmUIIDs(_ ids: Set<UUID>) {
        saveUUIDSet(ids, forKey: pendingWakeUpCheckShowConfirmUIIDsKey)
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
