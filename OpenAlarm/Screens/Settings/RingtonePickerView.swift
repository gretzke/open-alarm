import AVFoundation
import SwiftUI

struct RingtonePickerView: View {
    @Binding var settings: SharedAlarmSettings
    @StateObject private var previewPlayer = RingtonePreviewPlayer()

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { settings.ringtoneShuffleEnabled },
                    set: { enabled in
                        Haptics.impact()
                        settings.setRingtoneShuffleEnabled(enabled)
                    }
                )) {
                    Label(L10n.ringtoneShuffleToggle, systemImage: "shuffle")
                }
                .tint(OAColor.actionCyan)
            }

            ForEach(RingtoneCatalog.sections, id: \.0) { section, ringtones in
                Section(LocalizedStringKey(section.displayNameKey)) {
                    ForEach(ringtones, id: \.id) { ringtone in
                        Button {
                            settings.selectRingtone(ringtone.id)
                            previewPlayer.play(ringtone)
                        } label: {
                            HStack {
                                Text(LocalizedStringKey(ringtone.displayNameKey))
                                Spacer()
                                if settings.selectedRingtoneIDs.contains(ringtone.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(OAColor.actionCyan)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.ringtonePickerTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            previewPlayer.stop()
        }
    }
}

@MainActor
private final class RingtonePreviewPlayer: ObservableObject {
    private var player: AVAudioPlayer?

    func play(_ ringtone: Ringtone) {
        stop()

        let fileURL = URL(fileURLWithPath: ringtone.excerptFileName)
        guard let url = Bundle.main.url(
            forResource: fileURL.deletingPathExtension().lastPathComponent,
            withExtension: fileURL.pathExtension
        ) else {
            return
        }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)

        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.numberOfLoops = 0
        self.player = player
        player.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
