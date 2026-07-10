import SwiftUI

struct ShakeConfigurator: View {
    @Binding private var task: AlarmTask

    init(task: Binding<AlarmTask>) {
        _task = task
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OASpacing.m) {
            Text(L10n.taskShakeIntensityTitle)
                .font(OAType.sectionLabel)
                .foregroundStyle(OAColor.textPrimary)

            SteppedSlider(
                value: intensity,
                range: 1...5,
                labels: [
                    L10n.taskShakeLevel1,
                    L10n.taskShakeLevel2,
                    L10n.taskShakeLevel3,
                    L10n.taskShakeLevel4,
                    L10n.taskShakeLevel5
                ]
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
}
