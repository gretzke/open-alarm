import SwiftUI

struct OnboardingFlowView: View {
    @ObservedObject var engine: OnboardingEngine
    @EnvironmentObject private var alarmStore: AlarmStore

    var body: some View {
        Group {
            switch engine.activeStep {
            case .oneTime(.welcome):
                WelcomeStepView {
                    engine.completeOneTimeWelcome()
                }

            case .oneTime(.defaultSharedSettings):
                DefaultSharedSettingsStepView(
                    initialSettings: alarmStore.defaultSharedSettings,
                    onSave: { settings in
                        alarmStore.updateDefaultSharedSettings(settings)
                        engine.completeOneTimeDefaultSharedSettings()
                    },
                    onSkip: {
                        engine.skipOneTimeDefaultSharedSettings()
                    }
                )

            case .reusable(.alarmPermissionPrePrompt):
                AlarmPermissionPrePromptStepView {
                    await engine.requestAlarmPermission()
                }

            case .reusable(.alarmPermissionDenied):
                AlarmPermissionDeniedStepView(
                    onOpenSettings: {
                        engine.openSettings()
                    }
                )

            case .none:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OAColor.background.ignoresSafeArea())
    }
}

private struct WelcomeStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 20) {
                Image("BrandIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220)
                    .shadow(color: OAColor.glassGlow, radius: 18, x: 0, y: 10)

                Text(L10n.onboardingWelcomeTitle)
                    .font(.title.bold())
                    .foregroundStyle(OAColor.textPrimary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        BenefitRow(text: L10n.onboardingWelcomeNoSubscriptions)
                        BenefitRow(text: L10n.onboardingWelcomeNoAds)
                        BenefitRow(text: L10n.onboardingWelcomeNoTracking)
                        BenefitRow(text: L10n.onboardingWelcomeOpenSource)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Image(systemName: "infinity")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(OAColor.actionCyan)

                        Text(L10n.onboardingWelcomeForever)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(OAColor.actionCyan)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
            }
            .padding(OASpacing.onboardingMargin)
            .oaGlassCard()

            Button(action: onNext) {
                Text(L10n.actionNext)
                    .font(OAType.buttonLabel)
                    .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
            }
            .buttonStyle(.glassProminent)
            .tint(OAColor.actionCyan)
            .accessibilityIdentifier("onboarding_welcome_next")
        }
        .padding(OASpacing.onboardingMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OAColor.background.ignoresSafeArea())
    }
}

private struct DefaultSharedSettingsStepView: View {
    let initialSettings: SharedAlarmSettings
    let onSave: (SharedAlarmSettings) -> Void
    let onSkip: () -> Void

    @EnvironmentObject private var alarmStore: AlarmStore
    @State private var settings: SharedAlarmSettings = .featureDefaults

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.onboardingDefaultConfigTitle)
                    .font(.title.bold())
                    .foregroundStyle(OAColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(L10n.onboardingDefaultConfigBody)
                    .font(.body)
                    .foregroundStyle(OAColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(L10n.onboardingDefaultConfigHint)
                    .font(.footnote)
                    .foregroundStyle(OAColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                SharedAlarmSettingsEditor(
                    settings: $settings,
                    allowFiveSecondSnoozeOption: alarmStore.testingModeEnabled
                )
            }
            .padding(OASpacing.onboardingMargin)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: OASpacing.m) {
                Button(action: onSkip) {
                    Text(L10n.actionSkip)
                        .font(OAType.buttonLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
                }
                .buttonStyle(.glass)

                Button {
                    onSave(settings)
                } label: {
                    Text(L10n.actionNext)
                        .font(OAType.buttonLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
                }
                .buttonStyle(.glassProminent)
                .tint(OAColor.actionCyan)
            }
            .padding(.horizontal, OASpacing.onboardingMargin)
            .padding(.vertical, OASpacing.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OAColor.background.ignoresSafeArea())
        .onAppear {
            settings = initialSettings
        }
    }
}

private struct AlarmPermissionPrePromptStepView: View {
    let requestPermission: () async -> Void
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "alarm.waves.left.and.right.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(OAColor.actionCyan)

                Text(L10n.onboardingPermissionRequestTitle)
                    .font(.title.bold())
                    .foregroundStyle(OAColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(L10n.onboardingPermissionRequestBody)
                    .font(.body)
                    .foregroundStyle(OAColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(OASpacing.onboardingMargin)
            .oaGlassCard()

            Button {
                guard !isRequesting else {
                    return
                }

                isRequesting = true
                Task {
                    await requestPermission()
                    isRequesting = false
                }
            } label: {
                HStack(spacing: 10) {
                    if isRequesting {
                        ProgressView()
                            .tint(OAColor.textPrimary)
                    }

                    Text(isRequesting ? L10n.actionRequesting : L10n.actionNext)
                        .font(OAType.buttonLabel)
                }
                .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
            }
            .buttonStyle(.glassProminent)
            .tint(OAColor.actionCyan)
            .disabled(isRequesting)
            .accessibilityIdentifier("onboarding_permission_request_next")
        }
        .padding(OASpacing.onboardingMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OAColor.background.ignoresSafeArea())
    }
}

private struct AlarmPermissionDeniedStepView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 50, weight: .semibold))
                    .foregroundStyle(OAColor.danger)

                Text(L10n.onboardingPermissionDeniedTitle)
                    .font(.title.bold())
                    .foregroundStyle(OAColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(L10n.onboardingPermissionDeniedBody)
                    .font(.body)
                    .foregroundStyle(OAColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(OASpacing.onboardingMargin)
            .oaGlassCard()

            Button(action: onOpenSettings) {
                Text(L10n.actionOpenSettings)
                    .font(OAType.buttonLabel)
                    .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
            }
            .buttonStyle(.glassProminent)
            .tint(OAColor.actionCyan)
            .accessibilityIdentifier("onboarding_permission_denied_open_settings")
        }
        .padding(OASpacing.onboardingMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OAColor.background.ignoresSafeArea())
    }
}

private struct BenefitRow: View {
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(OAColor.actionCyan)

            Text(text)
                .font(.body.weight(.medium))
                .foregroundStyle(OAColor.textPrimary)

            Spacer(minLength: 0)
        }
    }
}

#Preview {
    OnboardingFlowView(engine: OnboardingEngine())
        .environmentObject(AlarmStore())
}
