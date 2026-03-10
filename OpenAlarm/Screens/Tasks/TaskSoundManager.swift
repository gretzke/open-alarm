import AVFoundation
import MediaPlayer
import SwiftUI

@MainActor
final class TaskSoundManager: ObservableObject {
    private var audioPlayer: AVAudioPlayer?
    private var volumeObservation: NSKeyValueObservation?
    private var volumePollingTimer: Timer?
    private var capturedVolume: Float?
    private var hiddenVolumeView: MPVolumeView?
    private var isResettingVolume = false

    /// Target volume for alarm playback. Future: make this configurable per alarm.
    private let alarmVolume: Float = 0.2

    func startPlaying() {
        configureAudioSession()
        setupHiddenVolumeView()
        setSystemVolume(alarmVolume)
        capturedVolume = alarmVolume
        playAlarmSound()
        observeVolumeChanges()
        startVolumePolling()
    }

    func stopPlaying() {
        volumePollingTimer?.invalidate()
        volumePollingTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        volumeObservation?.invalidate()
        volumeObservation = nil
        capturedVolume = nil
        hiddenVolumeView?.removeFromSuperview()
        hiddenVolumeView = nil
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }

    private func playAlarmSound() {
        // Try bundled sound first, fall back to system alarm sound
        let url = Bundle.main.url(forResource: "alarm_sound", withExtension: "caf")
            ?? Bundle.main.url(forResource: "alarm_sound", withExtension: "mp3")
            ?? URL(fileURLWithPath: "/System/Library/Audio/UISounds/alarm.caf")

        attemptPlay(url: url, retriesLeft: 3)
    }

    private func attemptPlay(url: URL, retriesLeft: Int) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.numberOfLoops = -1
        player.prepareToPlay()
        player.play()
        audioPlayer = player

        // Verify playback actually started; if not, retry.
        // play() can return true but produce no audio if the session isn't routed yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if self.audioPlayer?.isPlaying != true, retriesLeft > 0 {
                self.audioPlayer = nil
                self.configureAudioSession()
                self.attemptPlay(url: url, retriesLeft: retriesLeft - 1)
            }
        }
    }

    private func observeVolumeChanges() {
        let session = AVAudioSession.sharedInstance()
        volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let newVolume = change.newValue else { return }
            DispatchQueue.main.async { [weak self] in
                self?.handleVolumeChange(newVolume)
            }
        }
    }

    /// Polling backup — catches volume changes that KVO misses or resets
    /// volume during held-down button presses where KVO only fires once.
    private func startVolumePolling() {
        volumePollingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let capturedVolume = self.capturedVolume else { return }
                let currentVolume = AVAudioSession.sharedInstance().outputVolume
                if abs(currentVolume - capturedVolume) > 0.01 {
                    self.setSystemVolume(capturedVolume)
                }
            }
        }
    }

    private func handleVolumeChange(_ newVolume: Float) {
        guard let capturedVolume, !isResettingVolume else { return }
        guard abs(newVolume - capturedVolume) > 0.01 else { return }
        setSystemVolume(capturedVolume)
    }

    private func setupHiddenVolumeView() {
        let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        volumeView.alpha = 0.01
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            window.addSubview(volumeView)
        }
        hiddenVolumeView = volumeView
    }

    private func setSystemVolume(_ volume: Float) {
        isResettingVolume = true
        if let slider = hiddenVolumeView?.subviews.first(where: { $0 is UISlider }) as? UISlider {
            slider.value = volume
            slider.sendActions(for: .valueChanged)
        }
        // Allow small delay for the system to process before re-enabling detection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isResettingVolume = false
        }
    }
}
