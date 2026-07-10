import AVFoundation
import CoreHaptics

@MainActor
final class HapticRamp {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var intentionallyStopped = false
    private var isPlaying = false
    private var lastProgress = 0.0
    private var lastFallbackStep = 0

    init() {
        createEngineAndPlayer()
    }

    func update(progress: Double) {
        let clampedProgress = min(max(progress, 0), 1)
        lastProgress = clampedProgress

        guard let player else {
            emitFallbackIfNeeded(progress: clampedProgress)
            return
        }

        do {
            if !isPlaying {
                try player.start(atTime: CHHapticTimeImmediate)
                isPlaying = true
            }

            let parameters = [
                CHHapticDynamicParameter(
                    parameterID: .hapticIntensityControl,
                    value: Float(0.2 + 0.8 * clampedProgress),
                    relativeTime: 0
                ),
                CHHapticDynamicParameter(
                    parameterID: .hapticSharpnessControl,
                    value: Float(0.3 + 0.5 * clampedProgress),
                    relativeTime: 0
                )
            ]
            try player.sendParameters(parameters, atTime: CHHapticTimeImmediate)
        } catch {
            self.player = nil
            isPlaying = false
            emitFallbackIfNeeded(progress: clampedProgress)
        }
    }

    func stop() {
        intentionallyStopped = true
        if isPlaying {
            try? player?.stop(atTime: CHHapticTimeImmediate)
        }
        isPlaying = false
        try? engine?.stop()
    }

    private func createEngineAndPlayer() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            return
        }

        do {
            let newEngine = try CHHapticEngine(audioSession: AVAudioSession.sharedInstance())
            newEngine.stoppedHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.restartAfterUnexpectedStop()
                }
            }
            newEngine.resetHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.recreateAfterReset()
                }
            }

            try newEngine.start()

            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.2),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
                ],
                relativeTime: 0,
                duration: 60
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])

            engine = newEngine
            player = try newEngine.makeAdvancedPlayer(with: pattern)
        } catch {
            engine = nil
            player = nil
            isPlaying = false
        }
    }

    /// A stopped engine can retain its continuous player, so only restart it.
    private func restartAfterUnexpectedStop() {
        guard !intentionallyStopped, let engine else {
            return
        }

        do {
            try engine.start()
        } catch {
            self.engine = nil
            player = nil
            isPlaying = false
        }
    }

    /// A reset invalidates all players. Recreate both engine and player, then
    /// resume the current ramp if the view was actively shaking.
    private func recreateAfterReset() {
        guard !intentionallyStopped else {
            return
        }

        let shouldResume = isPlaying
        engine = nil
        player = nil
        isPlaying = false
        createEngineAndPlayer()

        if shouldResume {
            update(progress: lastProgress)
        }
    }

    private func emitFallbackIfNeeded(progress: Double) {
        let step = Int((progress * 4).rounded(.down))
        guard step > lastFallbackStep else {
            return
        }

        lastFallbackStep = step
        Haptics.impact(step >= 3 ? .medium : .light)
    }
}
