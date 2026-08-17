import Foundation
import Testing

@testable import OpenAlarm

@MainActor
struct OnboardingPermissionReconciliationTests {
    @Test
    func notificationRuleUsesRestoredDefaultsAndStopsWhenAuthorized() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        var settings = SharedAlarmSettings.featureDefaults
        settings.wakeUpCheckEnabled = true
        context.persistence.saveDefaultSharedSettings(settings)

        let engine = context.makeEngine()

        #expect(engine.activeStep == .reusable(.notificationPermissionPrePrompt))

        context.notificationPermissionStatus = .authorized
        engine.recheckReusableScreens()

        #expect(engine.activeStep == nil)
    }

    @Test
    func notificationDismissalUsesCurrentRequirementsFingerprint() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        var settings = SharedAlarmSettings.featureDefaults
        settings.wakeUpCheckEnabled = true
        context.persistence.saveDefaultSharedSettings(settings)

        let engine = context.makeEngine()
        #expect(engine.activeStep == .reusable(.notificationPermissionPrePrompt))

        engine.dismissActivePermissionReconciliation()
        #expect(engine.activeStep == nil)

        let matchingConfigurationEngine = context.makeEngine()
        #expect(matchingConfigurationEngine.activeStep == nil)

        settings.tasksEnabled = true
        settings.tasks = [.scanObject(objectClass: "mug")]
        context.persistence.saveDefaultSharedSettings(settings)
        context.taskPermissionStatuses[.camera] = .authorized

        let changedConfigurationEngine = context.makeEngine()
        #expect(changedConfigurationEngine.activeStep == .reusable(.notificationPermissionPrePrompt))
    }

    @Test
    func scanTaskRequiresCameraPermission() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        context.persistence.saveDefaultSharedSettings(settings(tasks: [.scanObject(objectClass: "mug")]))

        let engine = context.makeEngine()

        #expect(engine.activeStep == .reusable(.taskPermissionPrePrompt(.camera)))
    }

    @Test
    func stepsTaskRequiresMotionPermission() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        context.persistence.saveDefaultSharedSettings(settings(tasks: [.steps(count: 30)]))

        let engine = context.makeEngine()

        #expect(engine.activeStep == .reusable(.taskPermissionPrePrompt(.motion)))
    }

    @Test
    func cameraPermissionComesBeforeMotionPermission() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        context.persistence.saveDefaultSharedSettings(
            settings(tasks: [.steps(count: 30), .scanObject(objectClass: "mug")])
        )

        let engine = context.makeEngine()

        #expect(engine.activeStep == .reusable(.taskPermissionPrePrompt(.camera)))
    }

    @Test
    func disabledAlarmCustomSettingsDoNotRequirePermissions() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        context.alarms = [makeRegularAlarm(
            settings: settings(tasks: [.scanObject(objectClass: "mug")]),
            isEnabled: false
        )]

        let engine = context.makeEngine()

        #expect(engine.activeStep == nil)
    }

    @Test
    func enabledDefaultAlarmIgnoresDormantCustomSettings() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        context.alarms = [makeRegularAlarm(
            settings: settings(tasks: [.scanObject(objectClass: "mug")]),
            useDefaultSettings: true
        )]

        let engine = context.makeEngine()

        #expect(engine.activeStep == nil)
    }

    @Test
    func napAlarmResolvesAgainstNapDefaults() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        context.persistence.saveNapDefaultSharedSettings(settings(tasks: [.steps(count: 30)]))
        context.alarms = [makeNapAlarm(useDefaultSettings: true)]

        let engine = context.makeEngine()

        #expect(engine.activeStep == .reusable(.taskPermissionPrePrompt(.motion)))
    }

    @Test
    func restoredDefaultsRequirePermissionsWithoutAlarms() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        context.persistence.saveDefaultSharedSettings(settings(tasks: [.scanObject(objectClass: "mug")]))

        let engine = context.makeEngine()

        #expect(context.alarms.isEmpty)
        #expect(engine.activeStep == .reusable(.taskPermissionPrePrompt(.camera)))
    }

    @Test
    func onlyOnePermissionReconciliationStepAppearsPerForegroundSession() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        context.persistence.saveDefaultSharedSettings(
            settings(tasks: [.scanObject(objectClass: "mug"), .steps(count: 30)])
        )

        let engine = context.makeEngine()
        #expect(engine.activeStep == .reusable(.taskPermissionPrePrompt(.camera)))

        engine.completeActivePermissionReconciliation()
        engine.recheckReusableScreens()

        #expect(engine.activeStep == nil)
    }

    @Test
    func alarmPermissionRuleOutranksPermissionReconciliation() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        context.alarmPermissionStatus = .notDetermined
        var settings = SharedAlarmSettings.featureDefaults
        settings.wakeUpCheckEnabled = true
        context.persistence.saveDefaultSharedSettings(settings)

        let engine = context.makeEngine()

        #expect(engine.activeStep == .reusable(.alarmPermissionPrePrompt))
    }

    @Test
    func uiTestSkipOnboardingStopsBeforePersistenceReads() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        var alarmProviderReadCount = 0
        let engine = OnboardingEngine(
            userDefaults: context.onboardingDefaults,
            alarmPersistence: context.persistence,
            alarmsProvider: {
                alarmProviderReadCount += 1
                return []
            },
            alarmPermissionStatusProvider: { .authorized },
            notificationPermissionStatusProvider: { .notDetermined },
            taskPermissionStatusProvider: { _ in .notDetermined },
            shouldSkipOnboarding: { true }
        )

        #expect(engine.activeStep == nil)
        #expect(alarmProviderReadCount == 0)
    }

    @Test
    func refreshKeepsAnEligibleActiveStepStable() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        context.persistence.saveDefaultSharedSettings(settings(tasks: [.scanObject(objectClass: "mug")]))
        let engine = context.makeEngine()
        #expect(engine.activeStep == .reusable(.taskPermissionPrePrompt(.camera)))

        var changedSettings = settings(tasks: [.scanObject(objectClass: "mug")])
        changedSettings.wakeUpCheckEnabled = true
        context.persistence.saveDefaultSharedSettings(changedSettings)

        engine.recheckReusableScreens()

        #expect(engine.activeStep == .reusable(.taskPermissionPrePrompt(.camera)))
    }

    private func settings(tasks: [AlarmTask]) -> SharedAlarmSettings {
        var settings = SharedAlarmSettings.featureDefaults
        settings.tasksEnabled = true
        settings.tasks = tasks
        return settings
    }

    private func makeRegularAlarm(
        settings: SharedAlarmSettings,
        useDefaultSettings: Bool = false,
        isEnabled: Bool = true
    ) -> UserAlarm {
        UserAlarm(
            trigger: .time(hour: 7, minute: 0),
            settingsMode: useDefaultSettings ? .useDefault : .custom(settings),
            isEnabled: isEnabled
        )
    }

    private func makeNapAlarm(useDefaultSettings: Bool) -> UserAlarm {
        UserAlarm(
            trigger: .fixed(.now.addingTimeInterval(60)),
            type: .nap(NapConfig(durationMinutes: 35, pausedRemainingSeconds: nil)),
            settingsMode: useDefaultSettings ? .useDefault : .custom(.featureDefaults)
        )
    }
}

@MainActor
extension OnboardingPermissionReconciliationTests {
    @Test
    func capAllowsRemainingPermissionOnNextAppOpen() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        context.persistence.saveDefaultSharedSettings(
            settings(tasks: [.scanObject(objectClass: "mug"), .steps(count: 30)])
        )

        let engine = context.makeEngine()
        #expect(engine.activeStep == .reusable(.taskPermissionPrePrompt(.camera)))

        context.taskPermissionStatuses[.camera] = .authorized
        engine.completeActivePermissionReconciliation()
        engine.recheckReusableScreens()
        #expect(engine.activeStep == nil)

        engine.handleAppOpened()
        #expect(engine.activeStep == .reusable(.taskPermissionPrePrompt(.motion)))
    }

    @Test
    func externalGrantAfterForegroundDoesNotChainASecondPrompt() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        context.persistence.saveDefaultSharedSettings(
            settings(tasks: [.scanObject(objectClass: "mug"), .steps(count: 30)])
        )

        let engine = context.makeEngine()
        #expect(engine.activeStep == .reusable(.taskPermissionPrePrompt(.camera)))

        // Foregrounding while the camera prompt is still up re-arms the
        // session flag through the passthrough branch.
        engine.handleAppOpened()
        #expect(engine.activeStep == .reusable(.taskPermissionPrePrompt(.camera)))

        // Camera granted externally (Settings app): the motion prompt must
        // wait for the next app open instead of chaining immediately.
        context.taskPermissionStatuses[.camera] = .authorized
        engine.recheckReusableScreens()
        #expect(engine.activeStep == nil)

        engine.handleAppOpened()
        #expect(engine.activeStep == .reusable(.taskPermissionPrePrompt(.motion)))
    }

    @Test
    func notificationPromptOutranksTaskPermissions() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        var restored = settings(tasks: [.scanObject(objectClass: "mug")])
        restored.wakeUpCheckEnabled = true
        context.persistence.saveDefaultSharedSettings(restored)

        let engine = context.makeEngine()
        #expect(engine.activeStep == .reusable(.notificationPermissionPrePrompt))
    }

    @Test
    func alarmPermissionDeniedTakesOverAfterActiveStepResolves() throws {
        let context = try PermissionReconciliationTestContext()
        defer { context.cleanUp() }

        context.persistence.saveDefaultSharedSettings(settings(tasks: [.scanObject(objectClass: "mug")]))

        let engine = context.makeEngine()
        #expect(engine.activeStep == .reusable(.taskPermissionPrePrompt(.camera)))

        // Mid-display denial does not yank the presented step (stability
        // guard), but the blocker takes over as soon as the step resolves.
        context.alarmPermissionStatus = .denied
        engine.recheckReusableScreens()
        #expect(engine.activeStep == .reusable(.taskPermissionPrePrompt(.camera)))

        context.taskPermissionStatuses[.camera] = .authorized
        engine.completeActivePermissionReconciliation()
        engine.recheckReusableScreens()
        #expect(engine.activeStep == .reusable(.alarmPermissionDenied))
    }
}

@MainActor
private final class PermissionReconciliationTestContext {
    let onboardingSuiteName: String
    let persistenceSuiteName: String
    let onboardingDefaults: UserDefaults
    let persistenceDefaults: UserDefaults
    let persistence: AlarmPersistence
    var alarms: [UserAlarm] = []
    var alarmPermissionStatus: AlarmPermissionStatus = .authorized
    var notificationPermissionStatus: NotificationPermissionStatus = .notDetermined
    var taskPermissionStatuses: [TaskPermission: TaskPermissionStatus] = [
        .camera: .notDetermined,
        .motion: .notDetermined
    ]

    init() throws {
        onboardingSuiteName = "openalarm-onboarding-tests-\(UUID().uuidString)"
        persistenceSuiteName = "openalarm-onboarding-persistence-tests-\(UUID().uuidString)"
        onboardingDefaults = try #require(UserDefaults(suiteName: onboardingSuiteName))
        persistenceDefaults = try #require(UserDefaults(suiteName: persistenceSuiteName))
        persistence = AlarmPersistence(defaults: persistenceDefaults)
        onboardingDefaults.set(
            [OneTimeOnboardingStep.welcome.rawValue, OneTimeOnboardingStep.defaultSharedSettings.rawValue],
            forKey: "ONBOARDING_ONE_TIME_COMPLETED_STEPS"
        )
    }

    func makeEngine() -> OnboardingEngine {
        OnboardingEngine(
            userDefaults: onboardingDefaults,
            alarmPersistence: persistence,
            alarmsProvider: { self.alarms },
            alarmPermissionStatusProvider: { self.alarmPermissionStatus },
            notificationPermissionStatusProvider: { self.notificationPermissionStatus },
            taskPermissionStatusProvider: { self.taskPermissionStatuses[$0] ?? .authorized },
            shouldSkipOnboarding: { false }
        )
    }

    func cleanUp() {
        onboardingDefaults.removePersistentDomain(forName: onboardingSuiteName)
        persistenceDefaults.removePersistentDomain(forName: persistenceSuiteName)
    }
}
