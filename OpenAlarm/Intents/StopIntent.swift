import AlarmKit
import AppIntents
import Foundation

struct StopIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop"
    static var description = IntentDescription("Stop an alarm")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "alarmID")
    var alarmID: String

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    init() {
        self.alarmID = ""
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else {
            return .result()
        }

        try? AlarmManager.shared.stop(id: id)

        let persistence = AlarmPersistenceV2()
        persistence.enqueuePendingEvent(
            PendingAlarmEvent(alarmID: id, kind: .stopped)
        )

        return .result()
    }
}
