import CryptoKit
import Foundation
import UIKit

enum OneTimeOnboardingStep: String, CaseIterable {
    case welcome
    case defaultSharedSettings
}

enum ReusableOnboardingStep: Hashable {
    case alarmPermissionPrePrompt
    case alarmPermissionDenied
    case notificationPermissionPrePrompt
    case taskPermissionPrePrompt(TaskPermission)

    var isPermissionReconciliation: Bool {
        switch self {
        case .notificationPermissionPrePrompt, .taskPermissionPrePrompt:
            true
        case .alarmPermissionPrePrompt, .alarmPermissionDenied:
            false
        }
    }

    var dismissalKey: String? {
        switch self {
        case .notificationPermissionPrePrompt:
            "notifications"
        case let .taskPermissionPrePrompt(permission):
            permission.dismissalKey
        case .alarmPermissionPrePrompt, .alarmPermissionDenied:
            nil
        }
    }
}

enum OnboardingStep: Hashable, Identifiable {
    case oneTime(OneTimeOnboardingStep)
    case reusable(ReusableOnboardingStep)

    var id: String {
        switch self {
        case let .oneTime(step):
            return "oneTime_\(step.rawValue)"
        case let .reusable(step):
            return "reusable_\(String(describing: step))"
        }
    }
}

private struct ReusableOnboardingRule {
    let id: String
    let priority: Int
    let buildStep: (OnboardingEvaluationContext) -> ReusableOnboardingStep?
}

private struct OnboardingEvaluationContext {
    let alarmPermissionStatus: AlarmPermissionStatus
    let notificationPermissionStatus: NotificationPermissionStatus
    let taskPermissionStatuses: [TaskPermission: TaskPermissionStatus]
    let requirements: PermissionRequirements
    let dismissedPermissionPromptFingerprints: [String: String]
}

private struct PermissionRequirements {
    let wakeCheckNeedsNotifications: Bool
    let requiredTaskPermissions: [TaskPermission]

    var dismissalFingerprint: String {
        let source = [
            "wakeCheckNeedsNotifications=\(wakeCheckNeedsNotifications)",
            "requiredTaskPermissions=\(requiredTaskPermissions.map(\.dismissalKey).joined(separator: ","))"
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class OnboardingEngine: ObservableObject {
    @Published private(set) var activeStep: OnboardingStep?

    private let userDefaults: UserDefaults
    private let alarmPermissionService: AlarmPermissionService
    private let alarmPersistence: AlarmPersistence
    private let alarmsProvider: () -> [UserAlarm]
    private let alarmPermissionStatusProvider: () -> AlarmPermissionStatus
    private var notificationPermissionStatusProvider: () -> NotificationPermissionStatus
    private let taskPermissionStatusProvider: (TaskPermission) -> TaskPermissionStatus
    private let shouldSkipOnboarding: () -> Bool
    private let oneTimeCompletedStepsKey = "ONBOARDING_ONE_TIME_COMPLETED_STEPS"
    private let dismissedPermissionPromptsKey = "ONBOARDING_DISMISSED_PERMISSION_PROMPTS_V1"
    private var hasShownPermissionReconciliationThisSession = false
    private var completedPermissionReconciliationThisSession = false

    private let oneTimeSteps: [OneTimeOnboardingStep] = [.welcome, .defaultSharedSettings]

    init(
        userDefaults: UserDefaults = .standard,
        alarmPermissionService: AlarmPermissionService? = nil,
        alarmPersistence: AlarmPersistence = .shared,
        alarmsProvider: (() -> [UserAlarm])? = nil,
        alarmPermissionStatusProvider: (() -> AlarmPermissionStatus)? = nil,
        notificationPermissionStatusProvider: @escaping () -> NotificationPermissionStatus = { .notDetermined },
        taskPermissionStatusProvider: @escaping (TaskPermission) -> TaskPermissionStatus = TaskPermissionAuthorizer.status(for:),
        shouldSkipOnboarding: @escaping () -> Bool = {
#if DEBUG
            ProcessInfo.processInfo.arguments.contains("uitestSkipOnboarding")
#else
            false
#endif
        }
    ) {
        let alarmPermissionService = alarmPermissionService ?? AlarmPermissionService()
        self.userDefaults = userDefaults
        self.alarmPermissionService = alarmPermissionService
        self.alarmPersistence = alarmPersistence
        self.alarmsProvider = alarmsProvider ?? { alarmPersistence.loadUserAlarms() }
        self.alarmPermissionStatusProvider = alarmPermissionStatusProvider ?? {
            alarmPermissionService.currentStatus()
        }
        self.notificationPermissionStatusProvider = notificationPermissionStatusProvider
        self.taskPermissionStatusProvider = taskPermissionStatusProvider
        self.shouldSkipOnboarding = shouldSkipOnboarding
        refreshWorkflow()
    }

    var isPresentingOnboarding: Bool {
        activeStep != nil
    }

    func handleAppOpened() {
        hasShownPermissionReconciliationThisSession = false
        completedPermissionReconciliationThisSession = false
        refreshWorkflow()
    }

    /// Late provider attachment: the engine is a @StateObject constructed
    /// before the store exists as installed state, so the store-backed
    /// notification status arrives after init.
    func attachNotificationPermissionStatusProvider(
        _ provider: @escaping () -> NotificationPermissionStatus
    ) {
        notificationPermissionStatusProvider = provider
        refreshWorkflow()
    }

    func completeOneTimeWelcome() {
        markOneTimeStepComplete(.welcome)
    }

    func completeOneTimeDefaultSharedSettings() {
        markOneTimeStepComplete(.defaultSharedSettings)
    }

    func completeRestoredDefaultSharedSettings() {
        markOneTimeStepComplete(.defaultSharedSettings)
    }

    func skipOneTimeDefaultSharedSettings() {
        markOneTimeStepComplete(.defaultSharedSettings)
    }

    func requestAlarmPermission() async {
        _ = await alarmPermissionService.requestAuthorization()
        refreshWorkflow()
    }

    func openSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(settingsURL)
    }

    func recheckReusableScreens() {
        refreshWorkflow()
    }

    func completeActivePermissionReconciliation() {
        guard case let .reusable(step) = activeStep, step.isPermissionReconciliation else {
            return
        }

        completedPermissionReconciliationThisSession = true
    }

    func dismissActivePermissionReconciliation() {
        guard case let .reusable(step) = activeStep,
              let dismissalKey = step.dismissalKey else {
            return
        }

        let requirements = permissionRequirements()
        var dismissed = loadDismissedPermissionPromptFingerprints()
        dismissed[dismissalKey] = requirements.dismissalFingerprint
        saveDismissedPermissionPromptFingerprints(dismissed)
        completedPermissionReconciliationThisSession = true
        refreshWorkflow()
    }

    private func markOneTimeStepComplete(_ step: OneTimeOnboardingStep) {
        var completed = loadCompletedOneTimeSteps()
        completed.insert(step)
        saveCompletedOneTimeSteps(completed)
        refreshWorkflow()
    }

    private func loadCompletedOneTimeSteps() -> Set<OneTimeOnboardingStep> {
        guard let raw = userDefaults.array(forKey: oneTimeCompletedStepsKey) as? [String] else {
            return []
        }

        return Set(raw.compactMap(OneTimeOnboardingStep.init(rawValue:)))
    }

    private func saveCompletedOneTimeSteps(_ completed: Set<OneTimeOnboardingStep>) {
        userDefaults.set(completed.map(\.rawValue), forKey: oneTimeCompletedStepsKey)
    }

    private func loadDismissedPermissionPromptFingerprints() -> [String: String] {
        userDefaults.dictionary(forKey: dismissedPermissionPromptsKey) as? [String: String] ?? [:]
    }

    private func saveDismissedPermissionPromptFingerprints(_ fingerprints: [String: String]) {
        userDefaults.set(fingerprints, forKey: dismissedPermissionPromptsKey)
    }

    private func permissionRequirements() -> PermissionRequirements {
        let defaultSharedSettings = alarmPersistence.loadDefaultSharedSettings()
        let napDefaultSharedSettings = alarmPersistence.loadNapDefaultSharedSettings()
        var settings = [defaultSharedSettings]

        if let napDefaultSharedSettings {
            settings.append(napDefaultSharedSettings)
        }

        for alarm in alarmsProvider() where alarm.isEnabled {
            let defaults = alarm.isNap
                ? napDefaultSharedSettings ?? defaultSharedSettings
                : defaultSharedSettings
            settings.append(alarm.resolvedSharedSettings(defaults: defaults))
        }

        let requiredTaskPermissions = Set(
            settings.flatMap { resolvedSettings in
                alarmPersistence.effectiveTasks(from: resolvedSettings).compactMap { task in
                    TaskRegistry.descriptor(for: task).requiredPermission
                }
            }
        )

        return PermissionRequirements(
            wakeCheckNeedsNotifications: settings.contains { $0.wakeUpCheckEnabled },
            requiredTaskPermissions: [.camera, .motion].filter(requiredTaskPermissions.contains)
        )
    }

    private func reusableRules(for requirements: PermissionRequirements) -> [ReusableOnboardingRule] {
        var rules = [
            ReusableOnboardingRule(id: "alarm_permission", priority: 0) { context in
                switch context.alarmPermissionStatus {
                case .authorized:
                    nil
                case .notDetermined:
                    .alarmPermissionPrePrompt
                case .denied:
                    .alarmPermissionDenied
                }
            },
            ReusableOnboardingRule(id: "notification_permission", priority: 1) { context in
                guard context.requirements.wakeCheckNeedsNotifications,
                      context.notificationPermissionStatus == .notDetermined,
                      context.dismissedPermissionPromptFingerprints["notifications"]
                        != context.requirements.dismissalFingerprint else {
                    return nil
                }
                return .notificationPermissionPrePrompt
            }
        ]

        rules.append(contentsOf: requirements.requiredTaskPermissions.map { permission in
            ReusableOnboardingRule(id: "task_permission_\(permission.dismissalKey)", priority: 2) { context in
                guard context.taskPermissionStatuses[permission] == .notDetermined,
                      context.dismissedPermissionPromptFingerprints[permission.dismissalKey]
                        != context.requirements.dismissalFingerprint else {
                    return nil
                }
                return .taskPermissionPrePrompt(permission)
            }
        })

        return rules
    }

    private func refreshWorkflow() {
        if shouldSkipOnboarding() {
            activeStep = nil
            return
        }

        let requirements = permissionRequirements()
        let context = OnboardingEvaluationContext(
            alarmPermissionStatus: alarmPermissionStatusProvider(),
            notificationPermissionStatus: notificationPermissionStatusProvider(),
            taskPermissionStatuses: Dictionary(
                uniqueKeysWithValues: requirements.requiredTaskPermissions.map { permission in
                    (permission, taskPermissionStatusProvider(permission))
                }
            ),
            requirements: requirements,
            dismissedPermissionPromptFingerprints: loadDismissedPermissionPromptFingerprints()
        )

        var workflow: [OnboardingStep] = []

        let completedOneTimeSteps = loadCompletedOneTimeSteps()

        if !completedOneTimeSteps.contains(.welcome) {
            workflow.append(.oneTime(.welcome))
        }

        let activePermissionReconciliationStep: ReusableOnboardingStep? = {
            guard case let .reusable(step) = activeStep, step.isPermissionReconciliation else {
                return nil
            }
            return step
        }()
        var hasIncludedPermissionReconciliation = false
        let reusableWorkflow = reusableRules(for: requirements)
            .sorted { lhs, rhs in
                if lhs.priority == rhs.priority {
                    return lhs.id < rhs.id
                }
                return lhs.priority < rhs.priority
            }
            .compactMap { $0.buildStep(context) }
            .filter { step in
                guard step.isPermissionReconciliation else {
                    return true
                }
                guard completedPermissionReconciliationThisSession == false else {
                    return false
                }
                if step == activePermissionReconciliationStep {
                    hasIncludedPermissionReconciliation = true
                    return true
                }
                guard hasShownPermissionReconciliationThisSession == false,
                      hasIncludedPermissionReconciliation == false else {
                    return false
                }
                hasIncludedPermissionReconciliation = true
                return true
            }
            .map(OnboardingStep.reusable)

        workflow.append(contentsOf: reusableWorkflow)

        if !completedOneTimeSteps.contains(.defaultSharedSettings) {
            workflow.append(.oneTime(.defaultSharedSettings))
        }

        if let activeStep, workflow.contains(activeStep) {
            // The preserved step still counts against the per-session cap —
            // handleAppOpened resets the flag before this refresh runs.
            if case let .reusable(step) = activeStep, step.isPermissionReconciliation {
                hasShownPermissionReconciliationThisSession = true
            }
            return
        }

        activeStep = workflow.first
        if case let .reusable(step) = activeStep, step.isPermissionReconciliation {
            hasShownPermissionReconciliationThisSession = true
        }
    }
}

private extension TaskPermission {
    var dismissalKey: String {
        switch self {
        case .camera:
            "camera"
        case .motion:
            "motion"
        }
    }
}
