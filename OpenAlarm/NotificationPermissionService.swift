import Foundation
import UserNotifications

@MainActor
final class NotificationPermissionService {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func currentStatus() async -> NotificationPermissionStatus {
        let settings = await center.notificationSettings()
        return map(settings.authorizationStatus)
    }

    func requestAuthorization() async -> NotificationPermissionStatus {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return await currentStatus()
        }

        return await currentStatus()
    }

    private func map(_ status: UNAuthorizationStatus) -> NotificationPermissionStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }
}
