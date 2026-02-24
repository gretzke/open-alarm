import SwiftUI

struct AppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var onboardingEngine = OnboardingEngine()
    @StateObject private var alarmStore = AlarmStore()

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
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                return
            }
            onboardingEngine.handleAppOpened()
            alarmStore.handleAppOpened()
        }
    }
}

#Preview {
    AppRootView()
}
