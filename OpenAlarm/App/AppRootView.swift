import SwiftUI

struct AppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    // The engine's default alarms provider reads the persisted blob, so it
    // stays current with intent-driven writes without a store reference.
    @StateObject private var onboardingEngine = OnboardingEngine(alarmPersistence: .shared)
    @StateObject private var alarmStore = AlarmStore()
    @State private var showWakeCheckPermissionDeniedPrompt = false
    @State private var bedsideNapID: UUID?
    @State private var bedsideDisplaySession = BedsideDisplaySession()

    var body: some View {
        Group {
            if onboardingEngine.isPresentingOnboarding {
                OnboardingFlowView(engine: onboardingEngine)
                    .environmentObject(alarmStore)
            } else {
                MainTabView(onPresentNapBedside: { bedsideNapID = $0 })
                    .environmentObject(alarmStore)
            }
        }
        .fontDesign(.rounded)
        .preferredColorScheme(.dark)
        .accessibilityHidden(bedsideNap != nil)
        .allowsHitTesting(bedsideNap == nil)
        .overlay {
            if let nap = bedsideNap {
                NapBedsideView(nap: nap, onClose: { bedsideNapID = nil })
                    .environmentObject(alarmStore)
            }
        }
        .onChange(of: bedsideNap != nil && scenePhase == .active, initial: true) { _, active in
            bedsideDisplaySession.setActive(active)
        }
        .onDisappear {
            bedsideDisplaySession.setActive(false)
        }
        .onChange(of: alarmStore.activeNap?.id) { _, id in
            if id != bedsideNapID { bedsideNapID = nil }
        }
        .onChange(of: alarmStore.disarmPresentation?.id) { _, id in
            if id != nil { bedsideNapID = nil }
        }
        .onChange(of: alarmStore.wakeUpCheckConfirmationPresentation?.id) { _, id in
            if id != nil { bedsideNapID = nil }
        }
        .onAppear {
            onboardingEngine.attachNotificationPermissionStatusProvider { [weak store = alarmStore] in
                store?.notificationPermissionStatus ?? .notDetermined
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

    private var bedsideNap: UserAlarm? {
        guard !onboardingEngine.isPresentingOnboarding,
              alarmStore.disarmPresentation == nil,
              alarmStore.wakeUpCheckConfirmationPresentation == nil,
              !showWakeCheckPermissionDeniedPrompt,
              let nap = alarmStore.activeNap, nap.id == bedsideNapID else { return nil }
        return nap
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
