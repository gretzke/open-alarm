import AlarmKit
import Foundation

enum AlarmPermissionStatus: Equatable {
    case notDetermined
    case denied
    case authorized
}

@MainActor
final class AlarmPermissionService {
    private let manager: AlarmManager

    init(manager: AlarmManager = .shared) {
        self.manager = manager
    }

    func currentStatus() -> AlarmPermissionStatus {
        map(manager.authorizationState)
    }

    func requestAuthorization() async -> AlarmPermissionStatus {
        do {
            let state = try await manager.requestAuthorization()
            return map(state)
        } catch {
            return currentStatus()
        }
    }

    private func map(_ state: AlarmManager.AuthorizationState) -> AlarmPermissionStatus {
        switch state {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .denied
        }
    }
}
