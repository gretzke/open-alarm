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

    @ScaledMetric(relativeTo: .largeTitle) private var dismissTimeFontSize: CGFloat = 84

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
            DawnBackground(progress: dawnProgress)

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

            VStack(spacing: OASpacing.m) {
                Text(alarm.name.isEmpty ? String(localized: "task_dismiss_title") : alarm.name)
                    .font(OADawnType.chip)
                    .foregroundStyle(dawnInk)
                    .padding(.horizontal, OASpacing.m)
                    .padding(.vertical, OASpacing.s)
                    .background(dawnInk.opacity(0.18), in: Capsule())

                Text(alarmTime)
                    .font(OADawnType.display(dismissTimeFontSize))
                    .monospacedDigit()
                    .foregroundStyle(dawnInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                if !tasks.isEmpty {
                    Text(L10n.taskDismissTasksHint(tasks.count))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(dawnInk.opacity(0.82))
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()

            Button {
                isDismissed = true
            } label: {
                Text(String(localized: "task_dismiss_alarm_button"))
                    .font(OADawnType.button)
                    .foregroundStyle(DawnPalette.inkDark)
                    .frame(maxWidth: .infinity, minHeight: OASize.controlHeight)
            }
            .background(Color.white, in: Capsule())
            .buttonStyle(.plain)

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
                        .font(OADawnType.chip)
                        .foregroundStyle(dawnInk)
                        .padding(.horizontal, OASpacing.m)
                        .padding(.vertical, OASpacing.s)
                        .background(dawnInk.opacity(0.18), in: Capsule())
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
                    .font(OADawnType.chip)
                    .foregroundStyle(dawnInk)
                    .padding(.horizontal, 14)
                    .frame(minHeight: OASize.minTouchTarget)
                }
                .background(dawnInk.opacity(0.18), in: Capsule())
                .buttonStyle(.plain)
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
            Haptics.success()
            Haptics.impact(.heavy)
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

    private var dawnProgress: Double {
        guard isDismissed, !tasks.isEmpty, currentTaskIndex < tasks.count else {
            return DawnProgress.dismiss
        }

        return DawnProgress.forTask(
            index: currentTaskIndex,
            of: tasks.count,
            within: withinTaskProgress
        )
    }

    private var dawnInk: Color {
        DawnPalette.ink(progress: dawnProgress)
    }

    private var alarmTime: String {
        var components = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: .now)
        components.hour = alarm.hour
        components.minute = alarm.minute
        let date = Calendar.autoupdatingCurrent.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}
