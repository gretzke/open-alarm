import Foundation

enum AlarmPermissionStatus: Equatable {
    case notDetermined
    case denied
    case authorized
}

enum NotificationPermissionStatus: Equatable {
    case notDetermined
    case denied
    case authorized
}

enum TaskPermission: Hashable {
    case camera
    case motion
}

enum TaskPermissionStatus: Equatable {
    case authorized
    case notDetermined
    case denied
}

@MainActor
protocol AlarmPermissionServicing: AnyObject {
    func currentStatus() -> AlarmPermissionStatus
    func requestAuthorization() async -> AlarmPermissionStatus
}

@MainActor
protocol NotificationPermissionServicing: AnyObject {
    func currentStatus() async -> NotificationPermissionStatus
    func requestAuthorization() async -> NotificationPermissionStatus
}
