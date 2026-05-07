import SwiftUI

struct AppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var onboardingEngine = OnboardingEngine()
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
            onboardingEngine.handleAppOpened()
            Task { await alarmStore.handleAppOpened() }
            evaluateWakeCheckPermissionGuard()
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
                resolvedSettings: presentation.resolvedSettings
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
                    alarmStore.disableWakeUpCheckFeatureGlobally()
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
            showWakeCheckPermissionDeniedPrompt = await alarmStore.shouldPresentWakeCheckPermissionDeniedPromptOnLaunch()
        }
    }
}

#Preview {
    AppRootView()
}
