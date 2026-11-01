@testable import OpenAlarmSchedulingCore

@MainActor
final class TestAlarmPermissions: AlarmPermissionServicing {
    func currentStatus() -> AlarmPermissionStatus { .authorized }
    func requestAuthorization() async -> AlarmPermissionStatus { .authorized }
}

@MainActor
final class TestNotificationPermissions: NotificationPermissionServicing {
    func currentStatus() async -> NotificationPermissionStatus { .authorized }
    func requestAuthorization() async -> NotificationPermissionStatus { .authorized }
}
