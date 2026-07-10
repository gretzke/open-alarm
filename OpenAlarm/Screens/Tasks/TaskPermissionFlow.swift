import AVFoundation
import CoreMotion
import SwiftUI

enum TaskPermissionStatus: Equatable {
    case authorized
    case notDetermined
    case denied
}

enum TaskPermissionFlowStep: String, Identifiable {
    case prePrompt
    case denied

    var id: String { rawValue }
}

@MainActor
enum TaskPermissionAuthorizer {
    static func status(for permission: TaskPermission) -> TaskPermissionStatus {
        switch permission {
        case .camera:
            return switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                .authorized
            case .notDetermined:
                .notDetermined
            case .denied, .restricted:
                .denied
            @unknown default:
                .denied
            }
        case .motion:
            guard CMPedometer.isStepCountingAvailable() else {
                return .authorized
            }

            return switch CMPedometer.authorizationStatus() {
            case .authorized:
                .authorized
            case .notDetermined:
                .notDetermined
            case .denied, .restricted:
                .denied
            @unknown default:
                .denied
            }
        }
    }

    static func request(_ permission: TaskPermission, completion: @escaping (Bool) -> Void) {
        switch permission {
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    completion(granted)
                }
            }
        case .motion:
            PedometerService.shared.requestAuthorization(completion)
        }
    }
}

struct TaskPermissionPrePromptView: View {
    let permission: TaskPermission
    let onRequestPermission: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: permission.systemImage)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(OAColor.actionCyan)

                Text(permission.prePromptTitle)
                    .font(.title.bold())
                    .foregroundStyle(OAColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(permission.prePromptBody)
                    .font(.body)
                    .foregroundStyle(OAColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(OASpacing.onboardingMargin)
            .oaGlassCard()

            VStack(spacing: 12) {
                Button(action: onRequestPermission) {
                    Text(L10n.actionNext)
                        .font(OAType.buttonLabel)
                        .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
                }
                .buttonStyle(.glassProminent)
                .tint(OAColor.actionCyan)
                .accessibilityIdentifier(permission.nextAccessibilityIdentifier)

                Button(action: onCancel) {
                    Text(L10n.actionCancel)
                        .font(OAType.buttonLabel)
                        .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
                }
                .buttonStyle(.glass)
                .foregroundStyle(OAColor.textPrimary)
                .accessibilityIdentifier(permission.cancelAccessibilityIdentifier)
            }
        }
        .padding(OASpacing.onboardingMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OAColor.background.ignoresSafeArea())
    }
}

struct TaskPermissionDeniedView: View {
    let permission: TaskPermission
    let onOpenSettings: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: permission.systemImage)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(OAColor.danger)

                Text(permission.deniedTitle)
                    .font(.title.bold())
                    .foregroundStyle(OAColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(permission.deniedBody)
                    .font(.body)
                    .foregroundStyle(OAColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(OASpacing.onboardingMargin)
            .oaGlassCard()

            VStack(spacing: 12) {
                Button(action: onOpenSettings) {
                    Text(L10n.actionOpenSettings)
                        .font(OAType.buttonLabel)
                        .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
                }
                .buttonStyle(.glassProminent)
                .tint(OAColor.actionCyan)
                .accessibilityIdentifier(permission.openSettingsAccessibilityIdentifier)

                Button(action: onCancel) {
                    Text(L10n.actionCancel)
                        .font(OAType.buttonLabel)
                        .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
                }
                .buttonStyle(.glass)
                .foregroundStyle(OAColor.textPrimary)
                .accessibilityIdentifier(permission.deniedCancelAccessibilityIdentifier)
            }
        }
        .padding(OASpacing.onboardingMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OAColor.background.ignoresSafeArea())
    }
}

private extension TaskPermission {
    var systemImage: String {
        switch self {
        case .camera: "camera.fill"
        case .motion: "figure.walk"
        }
    }

    var prePromptTitle: LocalizedStringKey {
        switch self {
        case .camera: L10n.taskScanCameraPermissionPromptTitle
        case .motion: L10n.taskStepsMotionPermissionPromptTitle
        }
    }

    var prePromptBody: LocalizedStringKey {
        switch self {
        case .camera: L10n.taskScanCameraPermissionPromptBody
        case .motion: L10n.taskStepsMotionPermissionPromptBody
        }
    }

    var deniedTitle: LocalizedStringKey {
        switch self {
        case .camera: L10n.taskScanCameraPermissionDeniedTitle
        case .motion: L10n.taskStepsMotionPermissionDeniedTitle
        }
    }

    var deniedBody: LocalizedStringKey {
        switch self {
        case .camera: L10n.taskScanCameraPermissionDeniedBody
        case .motion: L10n.taskStepsMotionPermissionDeniedBody
        }
    }

    var nextAccessibilityIdentifier: String {
        switch self {
        case .camera: "camera_permission_next"
        case .motion: "motion_permission_next"
        }
    }

    var cancelAccessibilityIdentifier: String {
        switch self {
        case .camera: "camera_permission_cancel"
        case .motion: "motion_permission_cancel"
        }
    }

    var openSettingsAccessibilityIdentifier: String {
        switch self {
        case .camera: "camera_permission_open_settings"
        case .motion: "motion_permission_open_settings"
        }
    }

    var deniedCancelAccessibilityIdentifier: String {
        switch self {
        case .camera: "camera_permission_denied_cancel"
        case .motion: "motion_permission_denied_cancel"
        }
    }
}
