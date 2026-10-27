import UIKit

@MainActor
final class BedsideDisplaySession {
    private let readIdleTimer: @MainActor () -> Bool
    private let writeIdleTimer: @MainActor (Bool) -> Void
    private var previousValue: Bool?

    init(
        readIdleTimer: @escaping @MainActor () -> Bool = { UIApplication.shared.isIdleTimerDisabled },
        writeIdleTimer: @escaping @MainActor (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }
    ) {
        self.readIdleTimer = readIdleTimer
        self.writeIdleTimer = writeIdleTimer
    }

    func setActive(_ active: Bool) {
        if active {
            guard previousValue == nil else { return }
            previousValue = readIdleTimer()
            writeIdleTimer(true)
        } else if let previousValue {
            writeIdleTimer(previousValue)
            self.previousValue = nil
        }
    }
}
