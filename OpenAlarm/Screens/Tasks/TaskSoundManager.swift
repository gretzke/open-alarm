import AVFoundation
import MediaPlayer
import SwiftUI

@MainActor
final class TaskSoundManager: ObservableObject {
    @Published private(set) var isAlarmSoundActive = false
    @Published private(set) var temporaryMuteRemainingSeconds = 0
    @Published private(set) var isTemporaryMuteRestoring = false

    private var audioPlayer: AVAudioPlayer?
    private var volumeObservation: NSKeyValueObservation?
    private var volumePollingTimer: Timer?
    private var temporaryMuteTimer: Timer?
    private var temporaryMuteFadeCompletionTask: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []
    private var capturedVolume: Float?
    private var hiddenVolumeView: MPVolumeView?
    private var isResettingVolume = false
    private var isPlaybackRequested = false
    private var alarmSoundURL: URL?
    private let volumeSettings: AlarmVolumeSettings
    private let pinSystemVolume: Bool
    private let ringtone: Ringtone
    private let alertStartedAt: Date
    private let normalPlayerVolume: Float = 1.0
    private let temporaryMuteDurationSeconds = 30
    private let temporaryMuteFadeDuration: TimeInterval = 2.5

    var isTemporaryMuteEngaged: Bool {
        temporaryMuteRemainingSeconds > 0 || isTemporaryMuteRestoring
    }

    init(
        volumeSettings: AlarmVolumeSettings = .default,
        pinSystemVolume: Bool = true,
        ringtone: Ringtone,
        alertStartedAt: Date
    ) {
        self.volumeSettings = volumeSettings
        self.pinSystemVolume = pinSystemVolume
        self.ringtone = ringtone
        self.alertStartedAt = alertStartedAt
    }

    func startPlaying() {
        let targetVolume = volumeSettings.targetScalar
        isPlaybackRequested = true
        isAlarmSoundActive = true
        alarmSoundURL = resolveAlarmSoundURL()
        configureAudioSession()
        registerForAudioSessionNotifications()
        if pinSystemVolume {
            setupHiddenVolumeView()
            setSystemVolume(targetVolume)
            capturedVolume = targetVolume
        }
        ensurePlaybackActive(forceRestart: true)
        if pinSystemVolume {
            observeVolumeChanges()
            startVolumePolling()
        }
    }

    func stopPlaying() {
        isPlaybackRequested = false
        isAlarmSoundActive = false
        cancelTemporaryMute()
        volumePollingTimer?.invalidate()
        volumePollingTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        volumeObservation?.invalidate()
        volumeObservation = nil
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
        capturedVolume = nil
        hiddenVolumeView?.removeFromSuperview()
        hiddenVolumeView = nil
        alarmSoundURL = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func temporarilyMuteAlarmSound() {
        guard isPlaybackRequested else { return }

        temporaryMuteFadeCompletionTask?.cancel()
        temporaryMuteFadeCompletionTask = nil
        isTemporaryMuteRestoring = false
        temporaryMuteRemainingSeconds = temporaryMuteDurationSeconds
        audioPlayer?.setVolume(0, fadeDuration: 0)
        startTemporaryMuteCountdown()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }

    private func resolveAlarmSoundURL() -> URL {
        if !ringtone.isDefault {
            let fileURL = URL(fileURLWithPath: ringtone.fullTrackFileName)
            let resourceName = fileURL.deletingPathExtension().lastPathComponent
            let fileExtension = fileURL.pathExtension
            if let resourceURL = Bundle.main.url(forResource: resourceName, withExtension: fileExtension) {
                return resourceURL
            }
        }

        return Bundle.main.url(forResource: "alarm_sound", withExtension: "caf")
            ?? Bundle.main.url(forResource: "alarm_sound", withExtension: "mp3")
            ?? URL(fileURLWithPath: "/System/Library/Audio/UISounds/alarm.caf")
    }

    private func ensurePlaybackActive(forceRestart: Bool = false) {
        guard isPlaybackRequested, let url = alarmSoundURL else { return }

        configureAudioSession()

        if let player = audioPlayer, !forceRestart, player.isPlaying {
            return
        }

        if let player = audioPlayer, !forceRestart {
            applyCurrentMuteState(to: player)
            seekToCurrentOffset(in: player)
            if player.play() {
                return
            }
        }

        attemptPlay(url: url, retriesLeft: 3)
    }

    private func attemptPlay(url: URL, retriesLeft: Int) {
        audioPlayer?.stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.numberOfLoops = -1
        applyCurrentMuteState(to: player)
        seekToCurrentOffset(in: player)
        player.prepareToPlay()
        guard player.play() else {
            if retriesLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.ensurePlaybackActive(forceRestart: true)
                }
            }
            return
        }
        audioPlayer = player

        // Verify playback actually started; if not, retry.
        // play() can return true but produce no audio if the session isn't routed yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if self.isPlaybackRequested, self.audioPlayer?.isPlaying != true, retriesLeft > 0 {
                self.audioPlayer = nil
                self.ensurePlaybackActive(forceRestart: true)
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

    private func registerForAudioSessionNotifications() {
        guard notificationObservers.isEmpty else { return }

        let center = NotificationCenter.default

        notificationObservers.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.ensurePlaybackActive()
                }
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleAudioInterruption(notification)
                }
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleRouteChange()
                }
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleMediaServicesReset()
                }
            }
        )
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard isPlaybackRequested else { return }

        let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let type = typeValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:))

        switch type {
        case .began:
            audioPlayer?.pause()
        case .ended:
            ensurePlaybackActive(forceRestart: true)
        case .none:
            break
        @unknown default:
            ensurePlaybackActive(forceRestart: true)
        }
    }

    private func handleRouteChange() {
        guard isPlaybackRequested else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.ensurePlaybackActive()
        }
    }

    private func handleMediaServicesReset() {
        guard isPlaybackRequested else { return }
        audioPlayer = nil
        ensurePlaybackActive(forceRestart: true)
    }

    private func startTemporaryMuteCountdown() {
        temporaryMuteTimer?.invalidate()
        temporaryMuteTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickTemporaryMuteCountdown()
            }
        }
    }

    private func tickTemporaryMuteCountdown() {
        guard temporaryMuteRemainingSeconds > 0 else { return }

        temporaryMuteRemainingSeconds -= 1
        if temporaryMuteRemainingSeconds == 0 {
            temporaryMuteTimer?.invalidate()
            temporaryMuteTimer = nil
            fadeAlarmSoundBackIn()
        }
    }

    private func fadeAlarmSoundBackIn() {
        temporaryMuteFadeCompletionTask?.cancel()
        isTemporaryMuteRestoring = true
        audioPlayer?.setVolume(normalPlayerVolume, fadeDuration: temporaryMuteFadeDuration)

        temporaryMuteFadeCompletionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(2_500_000_000))
            await MainActor.run { [weak self] in
                self?.finishTemporaryMuteFade()
            }
        }
    }

    private func finishTemporaryMuteFade() {
        temporaryMuteFadeCompletionTask = nil
        guard isPlaybackRequested else {
            isTemporaryMuteRestoring = false
            return
        }

        audioPlayer?.volume = normalPlayerVolume
        isTemporaryMuteRestoring = false
    }

    private func applyCurrentMuteState(to player: AVAudioPlayer) {
        if temporaryMuteRemainingSeconds > 0 {
            player.volume = 0
        } else if isTemporaryMuteRestoring {
            player.volume = 0
            player.setVolume(normalPlayerVolume, fadeDuration: temporaryMuteFadeDuration)
        } else if ringtone.isDefault {
            player.volume = normalPlayerVolume
        } else {
            player.volume = 0
            player.setVolume(normalPlayerVolume, fadeDuration: 0.5)
        }
    }

    private func seekToCurrentOffset(in player: AVAudioPlayer) {
        guard !ringtone.isDefault else { return }
        player.currentTime = RingtonePlayback.offset(
            alertStartedAt: alertStartedAt,
            now: .now,
            excerptDuration: ringtone.excerptDuration
        )
    }

    private func cancelTemporaryMute() {
        temporaryMuteTimer?.invalidate()
        temporaryMuteTimer = nil
        temporaryMuteFadeCompletionTask?.cancel()
        temporaryMuteFadeCompletionTask = nil
        temporaryMuteRemainingSeconds = 0
        isTemporaryMuteRestoring = false
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
