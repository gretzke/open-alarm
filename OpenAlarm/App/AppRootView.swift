import SwiftUI

struct AppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    // The engine's default alarms provider reads the persisted blob, so it
    // stays current with intent-driven writes without a store reference.
    @StateObject private var onboardingEngine = OnboardingEngine(alarmPersistence: .shared)
    @StateObject private var alarmStore = AlarmStore()
    @State private var showWakeCheckPermissionDeniedPrompt = false

    var body: some View {
        Group {
            if onboardingEngine.isPresentingOnboarding {
                OnboardingFlowView(engine: onboardingEngine)
                    .environmentObject(alarmStore)
            } else {
                MainTabView()
                    .environmentObject(alarmStore)
            }
        }
        .fontDesign(.rounded)
        .preferredColorScheme(.dark)
        .onAppear {
            onboardingEngine.attachNotificationPermissionStatusProvider { [weak alarmStore] in
                alarmStore?.notificationPermissionStatus ?? .notDetermined
            }
            completeRestoredSettingsOnboardingIfNeeded()
            onboardingEngine.handleAppOpened()
            Task { await alarmStore.handleAppOpened() }
            evaluateWakeCheckPermissionGuard()
        }
        .onChange(of: alarmStore.restoredAlarmSettingsFromICloud) { _, restored in
            guard restored else {
                return
            }
            completeRestoredSettingsOnboardingIfNeeded()
            evaluateWakeCheckPermissionGuard()
        }
        .onChange(of: alarmStore.notificationPermissionStatus) { _, _ in
            onboardingEngine.recheckReusableScreens()
        }
        .onChange(of: alarmStore.alarms) { _, _ in
            onboardingEngine.recheckReusableScreens()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                return
            }
            onboardingEngine.handleAppOpened()
            Task { await alarmStore.handleAppOpened() }
            evaluateWakeCheckPermissionGuard()
        }
        .onOpenURL { url in
            guard url.scheme == "openalarm" else {
                return
            }
            onboardingEngine.handleAppOpened()
            Task {
                await alarmStore.handleAppOpened()
                await alarmStore.handleOpenURL(url)
            }
        }
        .fullScreenCover(item: $alarmStore.disarmPresentation) { presentation in
            TaskContainerView(
                alarm: presentation.alarm,
                tasks: presentation.tasks,
                resolvedSettings: presentation.resolvedSettings,
                ringtone: presentation.ringtone,
                alertStartedAt: presentation.alertStartedAt,
                pinSystemVolume: alarmStore.pinAlarmVolumeEnabled
            ) {
                Task {
                    await alarmStore.completeDisarmChallenge(for: presentation.id)
                }
            }
        }
        .fullScreenCover(isPresented: $showWakeCheckPermissionDeniedPrompt) {
            WakeCheckPermissionDeniedView(
                onOpenSettings: {
                    showWakeCheckPermissionDeniedPrompt = false
                    alarmStore.openSettings()
                },
                onDisableFeature: {
                    Task { await alarmStore.disableWakeUpCheckFeatureGlobally() }
                    showWakeCheckPermissionDeniedPrompt = false
                }
            )
        }
        .fullScreenCover(item: $alarmStore.wakeUpCheckConfirmationPresentation) { presentation in
            WakeUpCheckConfirmationView(alarmID: presentation.id)
                .environmentObject(alarmStore)
        }
    }

    private func evaluateWakeCheckPermissionGuard() {
        // Don't show permission prompts during a disarm challenge
        guard alarmStore.disarmPresentation == nil else { return }
        Task { @MainActor in
            let shouldPresent = await alarmStore.shouldPresentWakeCheckPermissionDeniedPromptOnLaunch()
            guard alarmStore.disarmPresentation == nil else { return }
            showWakeCheckPermissionDeniedPrompt = shouldPresent
        }
    }

    private func completeRestoredSettingsOnboardingIfNeeded() {
        guard alarmStore.restoredAlarmSettingsFromICloud else {
            return
        }
        onboardingEngine.completeRestoredDefaultSharedSettings()
    }
}

#Preview {
    AppRootView()
}
