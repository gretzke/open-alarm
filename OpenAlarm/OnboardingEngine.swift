import Foundation
import UIKit

enum OneTimeOnboardingStep: String, CaseIterable {
    case welcome
    case defaultSharedSettings
}

enum ReusableOnboardingStep: Hashable {
    case alarmPermissionPrePrompt
    case alarmPermissionDenied
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

struct ReusableOnboardingRule {
    let id: String
    let priority: Int
    let buildStep: (OnboardingEvaluationContext) -> ReusableOnboardingStep?
}

struct OnboardingEvaluationContext {
    let alarmPermissionStatus: AlarmPermissionStatus
}

@MainActor
final class OnboardingEngine: ObservableObject {
    @Published private(set) var activeStep: OnboardingStep?

    private let userDefaults: UserDefaults
    private let alarmPermissionService: AlarmPermissionService
    private let oneTimeCompletedStepsKey = "ONBOARDING_ONE_TIME_COMPLETED_STEPS"

    private let oneTimeSteps: [OneTimeOnboardingStep] = [.welcome, .defaultSharedSettings]
    private lazy var reusableRules: [ReusableOnboardingRule] = [
        ReusableOnboardingRule(id: "alarm_permission", priority: 0) { context in
            switch context.alarmPermissionStatus {
            case .authorized:
                return nil
            case .notDetermined:
                return .alarmPermissionPrePrompt
            case .denied:
                return .alarmPermissionDenied
            }
        }
    ]

    init(
        userDefaults: UserDefaults = .standard,
        alarmPermissionService: AlarmPermissionService? = nil
    ) {
        self.userDefaults = userDefaults
        self.alarmPermissionService = alarmPermissionService ?? AlarmPermissionService()
        refreshWorkflow()
    }

    var isPresentingOnboarding: Bool {
        activeStep != nil
    }

    func handleAppOpened() {
        refreshWorkflow()
    }

    func completeOneTimeWelcome() {
        markOneTimeStepComplete(.welcome)
    }

    func completeOneTimeDefaultSharedSettings() {
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

    private func refreshWorkflow() {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("uitestSkipOnboarding") {
            activeStep = nil
            return
        }
#endif
        let context = OnboardingEvaluationContext(
            alarmPermissionStatus: alarmPermissionService.currentStatus()
        )

        var workflow: [OnboardingStep] = []

        let completedOneTimeSteps = loadCompletedOneTimeSteps()

        if !completedOneTimeSteps.contains(.welcome) {
            workflow.append(.oneTime(.welcome))
        }

        let reusableWorkflow = reusableRules
            .sorted { lhs, rhs in
                if lhs.priority == rhs.priority {
                    return lhs.id < rhs.id
                }
                return lhs.priority < rhs.priority
            }
            .compactMap { $0.buildStep(context) }
            .map(OnboardingStep.reusable)

        workflow.append(contentsOf: reusableWorkflow)

        if !completedOneTimeSteps.contains(.defaultSharedSettings) {
            workflow.append(.oneTime(.defaultSharedSettings))
        }

        activeStep = workflow.first
    }
}
