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
            .padding(24)
            .oaGlassCard()

            Button(action: onNext) {
                Text(L10n.actionNext)
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(OAColor.textPrimary)
                    .oaGlassProminentButtonChrome()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("onboarding_welcome_next")
        }
        .padding(24)
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

                HStack(spacing: 12) {
                    Button(action: onSkip) {
                        Text(L10n.actionSkip)
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(OAColor.textPrimary)
                            .oaGlassButtonChrome()
                    }
                    .buttonStyle(.plain)

                    Button {
                        onSave(settings)
                    } label: {
                        Text(L10n.actionNext)
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(OAColor.textPrimary)
                            .oaGlassProminentButtonChrome()
                    }
                    .buttonStyle(.plain)
                }

                SharedAlarmSettingsEditor(
                    settings: $settings,
                    allowFiveSecondSnoozeOption: alarmStore.testingModeEnabled
                )
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
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
            .padding(24)
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
                        .font(.headline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(OAColor.textPrimary)
                .oaGlassProminentButtonChrome()
            }
            .buttonStyle(.plain)
            .disabled(isRequesting)
            .accessibilityIdentifier("onboarding_permission_request_next")
        }
        .padding(24)
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
            .padding(24)
            .oaGlassCard()

            Button(action: onOpenSettings) {
                Text(L10n.actionOpenSettings)
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(OAColor.textPrimary)
                    .oaGlassProminentButtonChrome()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("onboarding_permission_denied_open_settings")
        }
        .padding(24)
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
