import UIKit

extension BedsideDisplaySession {
    convenience init() {
        self.init(
            readIdleTimer: { UIApplication.shared.isIdleTimerDisabled },
            writeIdleTimer: { UIApplication.shared.isIdleTimerDisabled = $0 }
        )
    }
}
