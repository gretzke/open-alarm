import CoreMotion
import Foundation

@MainActor
final class PedometerService {
    static let shared = PedometerService()

    private let pedometer = CMPedometer()
    private var updateSession: UUID?

    private init() {}

    var isAvailable: Bool {
        CMPedometer.isStepCountingAvailable()
    }

    var isDenied: Bool {
        switch CMPedometer.authorizationStatus() {
        case .denied, .restricted:
            true
        case .notDetermined, .authorized:
            false
        @unknown default:
            true
        }
    }

    /// Triggers the Motion & Fitness prompt (CMPedometer has no explicit request
    /// API; a query forces it) and reports the resulting authorization.
    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        pedometer.queryPedometerData(
            from: Date().addingTimeInterval(-60),
            to: Date()
        ) { _, _ in
            Task { @MainActor in
                completion(CMPedometer.authorizationStatus() == .authorized)
            }
        }
    }

    /// Begins a cumulative step count from now. This overload keeps the public
    /// service interface useful for callers that do not need error handling.
    func startUpdates(_ handler: @escaping (_ steps: Int) -> Void) {
        startUpdates(handler, onError: {})
    }

    /// The pedometer can report an asynchronous first-callback failure. The
    /// Steps view uses this internal extension to fail open rather than leaving
    /// a user trapped on a sensor-dependent task.
    func startUpdates(
        _ handler: @escaping (_ steps: Int) -> Void,
        onError: @escaping () -> Void
    ) {
        stopUpdates()

        // Starting updates can present the system prompt. Wake-time task views
        // must fail open instead; the picker requests authorization in advance.
        guard isAvailable, CMPedometer.authorizationStatus() == .authorized else {
            onError()
            return
        }

        let session = UUID()
        updateSession = session
        pedometer.startUpdates(from: Date()) { [weak self] data, error in
            Task { @MainActor [weak self] in
                guard let self, self.updateSession == session else {
                    return
                }

                guard error == nil, let data else {
                    self.stopUpdates()
                    onError()
                    return
                }

                handler(max(data.numberOfSteps.intValue, 0))
            }
        }
    }

    func stopUpdates() {
        updateSession = nil
        pedometer.stopUpdates()
    }
}
