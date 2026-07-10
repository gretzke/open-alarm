import AlarmKit
import SwiftUI

struct TaskContainerView: View {
    let alarm: AlarmDefinition
    let tasks: [AlarmTask]
    let resolvedSettings: SharedAlarmSettings
    var onCompleted: () -> Void

    @StateObject private var soundManager: TaskSoundManager
    @State private var forceCloseManager: ForceCloseAlarmManager?
    @State private var isDismissed = false
    @State private var currentTaskIndex = 0
    @State private var hasCompletedCurrentTask = false
    @State private var withinTaskProgress: Double = 0

    init(
        alarm: AlarmDefinition,
        tasks: [AlarmTask],
        resolvedSettings: SharedAlarmSettings,
        pinSystemVolume: Bool = true,
        onCompleted: @escaping () -> Void
    ) {
        self.alarm = alarm
        self.tasks = tasks
        self.resolvedSettings = resolvedSettings
        self.onCompleted = onCompleted
        _soundManager = StateObject(
            wrappedValue: TaskSoundManager(
                volumeSettings: resolvedSettings.volume,
                pinSystemVolume: pinSystemVolume
            )
        )
    }

    var body: some View {
        ZStack {
            OAColor.background.ignoresSafeArea()

            if !isDismissed {
                dismissScreen
            } else if tasks.isEmpty {
                Color.clear.onAppear { complete() }
            } else {
                challengeScreen
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            // Cancel any orphaned force-close alarm for this challenge from a previous app session.
            if let orphanedID = BackstopSlotStore.clear(forParent: alarm.id) {
                try? AlarmManager.shared.stop(id: orphanedID)
                try? AlarmManager.shared.cancel(id: orphanedID)
            }

            if alarm.isNap {
                NapCountdownLiveActivityManager.shared.stop()
            }
            soundManager.startPlaying()
            AlarmSoundLiveActivityManager.shared.start(alarm: alarm)
            let manager = ForceCloseAlarmManager(alarm: alarm, resolvedSettings: resolvedSettings)
            manager.start()
            forceCloseManager = manager
        }
        .onDisappear {
            soundManager.stopPlaying()
            forceCloseManager?.stop()
            AlarmSoundLiveActivityManager.shared.stop()
        }
    }

    private var dismissScreen: some View {
        VStack {
            soundControlHeader

            Spacer()

            Text(alarm.name.isEmpty ? String(localized: "task_dismiss_title") : alarm.name)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(OAColor.textPrimary)
                .multilineTextAlignment(.center)

            Spacer()

            Button {
                isDismissed = true
            } label: {
                Text(String(localized: "task_dismiss_alarm_button"))
                    .font(OAType.buttonLabel)
                    .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
            }
            .buttonStyle(.glassProminent)
            .tint(OAColor.actionCyan)

            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private var challengeScreen: some View {
        if currentTaskIndex < tasks.count {
            VStack {
                soundControlHeader

                if tasks.count > 1 {
                    Text(String(localized: "task_progress \(currentTaskIndex + 1) \(tasks.count)"))
                        .font(.subheadline)
                        .foregroundStyle(OAColor.textSecondary)
                        .padding(.top)
                }

                taskView(for: tasks[currentTaskIndex])
            }
        }
    }

    @ViewBuilder
    private var soundControlHeader: some View {
        HStack {
            Spacer(minLength: 0)

            if soundManager.isAlarmSoundActive {
                Button {
                    soundManager.temporarilyMuteAlarmSound()
                } label: {
                    Label {
                        Text(temporaryMuteButtonTitle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } icon: {
                        Image(systemName: "speaker.slash.fill")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OAColor.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: OASize.minTouchTarget)
                }
                .buttonStyle(.glassAccentBorder)
                .accessibilityLabel(temporaryMuteAccessibilityLabel)
                .accessibilityIdentifier("task_sound_temporary_mute")
            }
        }
        .padding(.top)
        .padding(.horizontal)
    }

    private var temporaryMuteButtonTitle: String {
        if soundManager.isTemporaryMuteEngaged {
            return String(localized: "task_mute_countdown \(soundManager.temporaryMuteRemainingSeconds)")
        }

        return String(localized: "task_mute_button")
    }

    private var temporaryMuteAccessibilityLabel: String {
        if soundManager.isTemporaryMuteEngaged {
            return String(localized: "a11y_task_mute_countdown \(soundManager.temporaryMuteRemainingSeconds)")
        }

        return String(localized: "a11y_task_mute_button")
    }

    private func taskView(for task: AlarmTask) -> some View {
        let index = currentTaskIndex
        return TaskRegistry.descriptor(for: task)
            .makeTaskView(task, mode: .wake) { event in
                handleTaskEvent(event, fromTaskAt: index)
            }
            .id(index)
    }

    private func handleTaskEvent(_ event: TaskEvent, fromTaskAt index: Int) {
        // A late event from an already-advanced leaf must not touch the next task.
        guard index == currentTaskIndex else { return }
        switch event {
        case .progress(let progress):
            withinTaskProgress = min(max(progress, 0), 1)
        case .completed:
            guard !hasCompletedCurrentTask else { return }
            hasCompletedCurrentTask = true
            advanceOrComplete()
        }
    }

    private func advanceOrComplete() {
        let nextIndex = currentTaskIndex + 1
        if nextIndex >= tasks.count {
            complete()
        } else {
            currentTaskIndex = nextIndex
            hasCompletedCurrentTask = false
            withinTaskProgress = 0
        }
    }

    private func complete() {
        soundManager.stopPlaying()
        AlarmSoundLiveActivityManager.shared.stop()
        forceCloseManager?.stop()
        onCompleted()
    }
}
