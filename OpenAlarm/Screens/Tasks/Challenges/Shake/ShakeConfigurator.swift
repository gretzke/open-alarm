import SwiftUI

struct ShakeConfigurator: View {
    @Binding private var task: AlarmTask

    init(task: Binding<AlarmTask>) {
        _task = task
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OASpacing.m) {
            ConfiguratorSlider(
                title: L10n.taskShakeIntensityTitle,
                value: intensity,
                in: 1...5,
                format: shakeLevelName
            )
        }
        .padding(OASpacing.m)
        .oaGlassPanel()
    }

    private var intensity: Binding<Int> {
        Binding(
            get: {
                guard case let .shake(intensity) = task else {
                    preconditionFailure("ShakeConfigurator received a non-shake task")
                }
                return min(max(intensity, 1), 5)
            },
            set: { newIntensity in
                task = .shake(intensity: min(max(newIntensity, 1), 5))
            }
        )
    }

    private func shakeLevelName(_ intensity: Int) -> String {
        switch intensity {
        case 1: L10n.taskShakeLevel1
        case 2: L10n.taskShakeLevel2
        case 3: L10n.taskShakeLevel3
        case 4: L10n.taskShakeLevel4
        default: L10n.taskShakeLevel5
        }
    }
}
