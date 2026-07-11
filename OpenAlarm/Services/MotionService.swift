import CoreMotion
import Foundation

@MainActor
final class MotionService {
    static let shared = MotionService()

    struct Token: Hashable {
        fileprivate let id = UUID()
    }

    typealias SampleHandler = (_ magnitude: Double, _ dt: Double) -> Void

    private let manager = CMMotionManager()
    private var subscribers: [UUID: SampleHandler] = [:]
    private var lastTimestamp: TimeInterval?
    /// Bumped on every start/stop so callbacks queued by an earlier
    /// start/stop cycle cannot act on the current subscriber set.
    private var generation = 0

    private init() {
        manager.deviceMotionUpdateInterval = 0.02
    }

    /// Adds a sensor consumer without disturbing existing consumers. The one
    /// shared manager is started for the first token and stopped for the last.
    /// Startup failures surface asynchronously; consumers detect them through
    /// their own sample-liveness watchdogs.
    func subscribe(_ handler: @escaping SampleHandler) -> Token? {
        guard manager.isDeviceMotionAvailable else {
            IntentDiagnostics.log("MotionService subscribe rejected: device motion unavailable")
            return nil
        }

        let token = Token()
        subscribers[token.id] = handler

        if subscribers.count == 1 {
            startUpdates()
        }

        return token
    }

    func cancel(_ token: Token) {
        guard subscribers.removeValue(forKey: token.id) != nil else {
            return
        }

        guard subscribers.isEmpty else {
            return
        }

        stopUpdates()
    }

    private func startUpdates() {
        generation += 1
        let startedGeneration = generation
        lastTimestamp = nil
        manager.deviceMotionUpdateInterval = 0.02
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            Task { @MainActor [weak self] in
                self?.receive(motion: motion, error: error, generation: startedGeneration)
            }
        }
    }

    private func stopUpdates() {
        generation += 1
        manager.stopDeviceMotionUpdates()
        lastTimestamp = nil
    }

    private func receive(motion: CMDeviceMotion?, error: Error?, generation: Int) {
        guard generation == self.generation else {
            return
        }

        if let error {
            let nsError = error as NSError
            // CoreMotion reports this once for a stationary device and keeps the
            // stream alive — it must not be treated as terminal (a phone lying
            // on a nightstand when the alarm rings triggers exactly this).
            let isRecoverable = nsError.domain == CMErrorDomain
                && nsError.code == Int(CMErrorDeviceRequiresMovement.rawValue)
            IntentDiagnostics.log(
                "MotionService error domain=\(nsError.domain) code=\(nsError.code) recoverable=\(isRecoverable)"
            )
            guard isRecoverable else {
                stopUpdates()
                subscribers.removeAll()
                return
            }
            return
        }

        guard let motion else {
            // Isolated nil sample: skip it, keep the stream.
            return
        }

        let timestamp = motion.timestamp
        let dt = lastTimestamp.map { max(timestamp - $0, 0) } ?? manager.deviceMotionUpdateInterval
        lastTimestamp = timestamp

        let acceleration = motion.userAcceleration
        let magnitude = sqrt(
            acceleration.x * acceleration.x
                + acceleration.y * acceleration.y
                + acceleration.z * acceleration.z
        )

        let currentHandlers = Array(subscribers.values)
        for handler in currentHandlers {
            handler(magnitude, dt)
        }
    }
}
