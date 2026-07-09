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

    init(
        alarm: AlarmDefinition,
        tasks: [AlarmTask],
        resolvedSettings: SharedAlarmSettings,
        onCompleted: @escaping () -> Void
    ) {
        self.alarm = alarm
        self.tasks = tasks
        self.resolvedSettings = resolvedSettings
        self.onCompleted = onCompleted
        _soundManager = StateObject(wrappedValue: TaskSoundManager(volumeSettings: resolvedSettings.volume))
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
            // Cancel any orphaned force-close alarm from a previous app session
            if let orphanedID = ForceCloseAlarmManager.loadPersistedForceCloseAlarmID() {
                try? AlarmManager.shared.stop(id: orphanedID)
                try? AlarmManager.shared.cancel(id: orphanedID)
                ForceCloseAlarmManager.clearPersistedForceCloseSlot()
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
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
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
    private func taskView(for task: AlarmTask) -> some View {
        switch task {
        case .dummy:
            DummyTaskView {
                advanceOrComplete()
            }
        case .math(let difficulty, let count):
            MathTaskView(difficulty: difficulty, totalCount: count) {
                advanceOrComplete()
            }
        }
    }

    private func advanceOrComplete() {
        let nextIndex = currentTaskIndex + 1
        if nextIndex >= tasks.count {
            complete()
        } else {
            currentTaskIndex = nextIndex
        }
    }

    private func complete() {
        soundManager.stopPlaying()
        AlarmSoundLiveActivityManager.shared.stop()
        forceCloseManager?.stop()
        onCompleted()
    }
}
