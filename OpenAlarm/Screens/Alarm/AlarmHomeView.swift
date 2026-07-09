import SwiftUI

struct AlarmHomeView: View {
    @EnvironmentObject private var alarmStore: AlarmStore
    @State private var editorRoute: AlarmEditorRoute?
    @State private var editorDetent: PresentationDetent = .fraction(0.82)
    @State private var isPresentingNapEditor = false
    @State private var pendingDisableConfirmationAlarm: UserAlarm?
    @State private var now = Date.now

    private let editorPartialDetent: PresentationDetent = .fraction(0.82)
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private func presentEditor(_ route: AlarmEditorRoute) {
        editorDetent = editorPartialDetent
        editorRoute = route
    }

    var body: some View {
        NavigationStack {
            List {
                napSection
                headerSection
                alarmListSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OAColor.background.ignoresSafeArea())
            .onAppear {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("uitestOpenCreateAlarm") {
                    presentEditor(.create)
                }
#endif
            }
            .onReceive(timer) { tick in
                now = tick
            }
        }
        .sheet(item: $editorRoute) { route in
            AlarmEditorView(route: route)
                .environmentObject(alarmStore)
                .presentationDetents([editorPartialDetent, .large], selection: $editorDetent)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isPresentingNapEditor) {
            NapEditorView(
                initialDraft: NapDraft(
                    totalMinutes: alarmStore.defaultNapDurationMinutes,
                    customSharedSettings: alarmStore.defaultSharedSettings
                )
            )
            .environmentObject(alarmStore)
            .presentationDetents([.fraction(0.4), .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Sections

    private var napSection: some View {
        Section {
            if let nap = alarmStore.activeNap, nap.remainingSeconds(referenceDate: now) > 0 || nap.isPaused {
                ActiveNapRowView(
                    nap: nap,
                    now: now,
                    onPause: {
                        Task {
                            await alarmStore.pauseNap()
                        }
                    },
                    onContinue: {
                        Task {
                            await alarmStore.resumeNap()
                        }
                    },
                    onAddOneMinute: {
                        Task {
                            await alarmStore.extendNap(byMinutes: 1)
                        }
                    },
                    onAddFiveMinutes: {
                        Task {
                            await alarmStore.extendNap(byMinutes: 5)
                        }
                    },
                    onAddTenMinutes: {
                        Task {
                            await alarmStore.extendNap(byMinutes: 10)
                        }
                    },
                    onDelete: {
                        alarmStore.deleteNap()
                    }
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                NapBannerView {
                    isPresentingNapEditor = true
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
    }

    private var headerSection: some View {
        Section {
            HStack(alignment: .center) {
                Text(L10n.alarmListTitle)
                    .font(OAType.screenTitle)
                    .foregroundStyle(OAColor.textPrimary)

                Spacer(minLength: 0)

                Button {
                    presentEditor(.create)
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(OAColor.actionCyan)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .overlay(
                            Circle()
                                .stroke(OAColor.glassStroke.opacity(0.85), lineWidth: 0.9)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("alarm_add_button")
            }
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var alarmListSection: some View {
        let alarmPresentations = alarmStore.regularAlarmPresentations

        if alarmPresentations.isEmpty {
            Section {
                ContentUnavailableView(
                    L10n.alarmListEmptyTitle,
                    systemImage: "alarm",
                    description: Text(L10n.alarmListEmptySubtitle)
                )
                .foregroundStyle(OAColor.textSecondary)
                .padding(.vertical, 24)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(alarmPresentations) { presentation in
                    let alarm = presentation.alarm
                    AlarmRowView(
                        alarm: alarm,
                        now: now,
                        isInteractive: presentation.isInteractive,
                        disableChoicePopoverPresented: presentation.isInteractive && pendingDisableConfirmationAlarm?.id == alarm.id,
                        onDisableChoicePopoverPresentedChange: { isPresented in
                            if !isPresented, pendingDisableConfirmationAlarm?.id == alarm.id {
                                pendingDisableConfirmationAlarm = nil
                            }
                        },
                        onSkipNextSelected: {
                            guard presentation.isInteractive else { return }
                            setAlarmEnabled(alarm, isOn: false, skipNext: true)
                            pendingDisableConfirmationAlarm = nil
                        },
                        onDisableCompletelySelected: {
                            guard presentation.isInteractive else { return }
                            setAlarmEnabled(alarm, isOn: false, skipNext: false)
                            pendingDisableConfirmationAlarm = nil
                        },
                        onToggle: { isOn in
                            guard presentation.isInteractive else { return }
                            handleAlarmToggle(alarm, isOn: isOn)
                        }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard presentation.isInteractive else { return }
                        presentEditor(.edit(alarm))
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if presentation.isInteractive {
                            Button(role: .destructive) {
                                alarmStore.deleteAlarm(alarm)
                            } label: {
                                Label(L10n.actionDelete, systemImage: "trash")
                            }
                            .tint(OAColor.danger)
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
    }

    // MARK: - Actions

    private func handleAlarmToggle(_ alarm: UserAlarm, isOn: Bool) {
        if !isOn, alarm.isRepeating, alarm.isEnabled {
            pendingDisableConfirmationAlarm = alarm
            return
        }

        setAlarmEnabled(alarm, isOn: isOn, skipNext: nil)
    }

    private func setAlarmEnabled(_ alarm: UserAlarm, isOn: Bool, skipNext: Bool?) {
        Task {
            try? await alarmStore.setAlarmEnabled(alarm, enabled: isOn, skipNext: skipNext)
        }
    }
}
