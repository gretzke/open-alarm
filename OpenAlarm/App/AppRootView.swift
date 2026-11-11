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
#if DEBUG
    @State private var debugChallenge = DebugLaunchPresentation.challengeFromArguments()
    @State private var debugWakeCheck = DebugLaunchPresentation.wakeCheckFromArguments()
#endif

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
#if DEBUG
        .fullScreenCover(item: $debugChallenge) { presentation in
            TaskContainerView(
                alarm: presentation.alarm,
                tasks: presentation.tasks,
                resolvedSettings: presentation.resolvedSettings,
                ringtone: presentation.ringtone,
                alertStartedAt: presentation.alertStartedAt,
                pinSystemVolume: false
            ) {
                debugChallenge = nil
            }
        }
        .fullScreenCover(item: $debugWakeCheck) { presentation in
            WakeUpCheckConfirmationView(alarmID: presentation.id)
                .environmentObject(alarmStore)
        }
#endif
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

#if DEBUG
/// Launch-argument hooks for screenshot runs. `uitestPresentChallenge <spec>`
/// presents the wake-up challenge for a synthetic alarm, where spec is
/// `memory:<difficulty>:<rounds>`, `math:<difficulty 1-5>:<count>`,
/// `shake:<intensity>`, `steps:<count>`, `scan`, `multi`, or `none`.
/// `uitestPresentWakeCheck` presents the wake-up check confirmation.
enum DebugLaunchPresentation {
    static let challengeArgument = "uitestPresentChallenge"
    static let wakeCheckArgument = "uitestPresentWakeCheck"

    static var isChallengeActive: Bool {
        ProcessInfo.processInfo.arguments.contains(challengeArgument)
    }

    static var isWakeCheckActive: Bool {
        ProcessInfo.processInfo.arguments.contains(wakeCheckArgument)
    }

    static func challengeFromArguments() -> DisarmPresentation? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: challengeArgument) else { return nil }
        let spec = arguments.indices.contains(index + 1) ? arguments[index + 1] : "memory:3:1"
        let alarm = AlarmDefinition(trigger: .time(hour: 6, minute: 30))
        var settings = SharedAlarmSettings.featureDefaults
        settings.tasks = tasks(for: spec)
        return DisarmPresentation(
            id: alarm.id,
            alarm: alarm,
            tasks: settings.tasks,
            resolvedSettings: settings,
            alertStartedAt: .now,
            ringtone: RingtoneCatalog.defaultTone
        )
    }

    static func wakeCheckFromArguments() -> WakeUpCheckConfirmationPresentation? {
        isWakeCheckActive ? WakeUpCheckConfirmationPresentation(id: UUID()) : nil
    }

    private static func tasks(for spec: String) -> [AlarmTask] {
        let parts = spec.split(separator: ":").map(String.init)
        let values = parts.dropFirst().compactMap { Int($0) }
        func value(_ index: Int, _ fallback: Int) -> Int {
            values.indices.contains(index) ? values[index] : fallback
        }
        switch parts.first ?? "" {
        case "memory":
            return [.memory(difficulty: value(0, 3), rounds: value(1, 1))]
        case "math":
            let difficulties = MathDifficulty.allCases
            let level = min(max(value(0, 2), 1), difficulties.count)
            return [.math(difficulty: difficulties[level - 1], count: value(1, 3))]
        case "shake":
            return [.shake(intensity: value(0, 3))]
        case "steps":
            return [.steps(count: value(0, 20))]
        case "scan":
            return [.scanObject(objectClass: ScanObjectCatalog.entries.first?.id ?? "cup")]
        case "multi":
            return [
                .memory(difficulty: 3, rounds: 1),
                .math(difficulty: .medium, count: 3),
                .shake(intensity: 3)
            ]
        default:
            return []
        }
    }
}
#endif

#Preview {
    AppRootView()
}
