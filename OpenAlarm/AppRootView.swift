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
            alarmStore.handleAppOpened()
            evaluateWakeCheckPermissionGuard()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                return
            }
            onboardingEngine.handleAppOpened()
            alarmStore.handleAppOpened()
            evaluateWakeCheckPermissionGuard()
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
    }

    private func evaluateWakeCheckPermissionGuard() {
        Task { @MainActor in
            showWakeCheckPermissionDeniedPrompt = await alarmStore.shouldPresentWakeCheckPermissionDeniedPromptOnLaunch()
        }
    }
}

#Preview {
    AppRootView()
}
