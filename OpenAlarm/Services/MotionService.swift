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

    private init() {
        manager.deviceMotionUpdateInterval = 0.02
    }

    /// Adds a sensor consumer without disturbing existing consumers. The one
    /// shared manager is started for the first token and stopped for the last.
    func subscribe(_ handler: @escaping SampleHandler) -> Token? {
        guard manager.isDeviceMotionAvailable else {
            return nil
        }

        let token = Token()
        subscribers[token.id] = handler

        if subscribers.count == 1 {
            lastTimestamp = nil
            manager.deviceMotionUpdateInterval = 0.02
            manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
                Task { @MainActor [weak self] in
                    self?.receive(motion: motion, error: error)
                }
            }

            // CMMotionManager has no throwing start API. This synchronous state
            // check is the available startup-failure signal; asynchronous errors
            // clear subscribers and are handled by each view's no-sample timeout.
            guard manager.isDeviceMotionActive else {
                subscribers.removeValue(forKey: token.id)
                lastTimestamp = nil
                return nil
            }
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

        manager.stopDeviceMotionUpdates()
        lastTimestamp = nil
    }

    private func receive(motion: CMDeviceMotion?, error: Error?) {
        guard error == nil, let motion else {
            manager.stopDeviceMotionUpdates()
            subscribers.removeAll()
            lastTimestamp = nil
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
