import Foundation

@MainActor
protocol AlarmScheduleReconcileHandling: AnyObject {
    func reconcileSchedule(target: AlarmScheduleReconcileTarget, referenceDate: Date, forceRearm: Bool) async
}

@MainActor
enum AlarmScheduleReconcileEntrypoint {
    private static weak var handler: (any AlarmScheduleReconcileHandling)?

    static func register(handler: any AlarmScheduleReconcileHandling) {
        self.handler = handler
    }

    static func unregister(handler: any AlarmScheduleReconcileHandling) {
        guard let current = self.handler else {
            return
        }

        if ObjectIdentifier(current) == ObjectIdentifier(handler) {
            self.handler = nil
        }
    }

    static func reconcileSchedule(
        alarmID: UUID,
        referenceDate: Date = .now,
        forceRearm: Bool = false
    ) async {
        await reconcile(target: .alarm(alarmID), referenceDate: referenceDate, forceRearm: forceRearm)
    }

    static func reconcileAllSchedules(referenceDate: Date = .now) async {
        await reconcile(target: .allAlarms, referenceDate: referenceDate, forceRearm: false)
    }

    static func reconcile(
        trigger: AlarmScheduleReconcileTrigger,
        referenceDate: Date = .now
    ) async {
        await reconcile(
            target: AlarmScheduleReconcileRouting.target(for: trigger),
            referenceDate: referenceDate,
            forceRearm: false
        )
    }

    private static func reconcile(
        target: AlarmScheduleReconcileTarget,
        referenceDate: Date,
        forceRearm: Bool
    ) async {
        guard let handler else {
            // App or store not ready yet. Intents should silently no-op.
            return
        }

        await handler.reconcileSchedule(target: target, referenceDate: referenceDate, forceRearm: forceRearm)
    }
}
