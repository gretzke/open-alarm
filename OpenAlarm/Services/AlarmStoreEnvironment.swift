import Foundation

/// Device services are supplied by the iOS app. Scheduling and persistence stay in AlarmStore.
@MainActor
struct AlarmStoreEnvironment {
    let liveActivitiesEnabled: () -> Bool
    let isInteractivelyVisible: () -> Bool
    let syncNapActivity: (UserAlarm?) -> Void
    let stopNapActivity: () -> Void
    let openSettings: () -> Void
    let protectedDataAvailableNotification: Notification.Name?
}
