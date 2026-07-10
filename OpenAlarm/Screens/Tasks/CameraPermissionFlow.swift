import SwiftUI

enum CameraPermissionFlowStep: String, Identifiable {
    case prePrompt
    case denied

    var id: String { rawValue }
}

struct CameraPermissionPrePromptView: View {
    let onRequestPermission: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(OAColor.actionCyan)

                Text(L10n.taskScanCameraPermissionPromptTitle)
                    .font(.title.bold())
                    .foregroundStyle(OAColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(L10n.taskScanCameraPermissionPromptBody)
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
                .accessibilityIdentifier("camera_permission_next")

                Button(action: onCancel) {
                    Text(L10n.actionCancel)
                        .font(OAType.buttonLabel)
                        .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
                }
                .buttonStyle(.glass)
                .foregroundStyle(OAColor.textPrimary)
                .accessibilityIdentifier("camera_permission_cancel")
            }
        }
        .padding(OASpacing.onboardingMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OAColor.background.ignoresSafeArea())
    }
}

struct CameraPermissionDeniedView: View {
    let onOpenSettings: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(OAColor.danger)

                Text(L10n.taskScanCameraPermissionDeniedTitle)
                    .font(.title.bold())
                    .foregroundStyle(OAColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(L10n.taskScanCameraPermissionDeniedBody)
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
                .accessibilityIdentifier("camera_permission_open_settings")

                Button(action: onCancel) {
                    Text(L10n.actionCancel)
                        .font(OAType.buttonLabel)
                        .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
                }
                .buttonStyle(.glass)
                .foregroundStyle(OAColor.textPrimary)
                .accessibilityIdentifier("camera_permission_denied_cancel")
            }
        }
        .padding(OASpacing.onboardingMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OAColor.background.ignoresSafeArea())
    }
}
