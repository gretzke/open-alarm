import AVFoundation
import SwiftUI

struct RingtonePickerView: View {
    @Binding var selection: String
    @StateObject private var previewPlayer = RingtonePreviewPlayer()

    var body: some View {
        List {
            ForEach(RingtoneCatalog.sections, id: \.0) { section, ringtones in
                Section(LocalizedStringKey(section.displayNameKey)) {
                    ForEach(ringtones, id: \.id) { ringtone in
                        Button {
                            selection = ringtone.id
                            previewPlayer.play(ringtone)
                        } label: {
                            HStack {
                                Text(LocalizedStringKey(ringtone.displayNameKey))
                                Spacer()
                                if selection == ringtone.id {
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

        let url: URL
        if ringtone.isDefault {
            url = Bundle.main.url(forResource: "alarm_sound", withExtension: "caf")
                ?? Bundle.main.url(forResource: "alarm_sound", withExtension: "mp3")
                ?? URL(fileURLWithPath: "/System/Library/Audio/UISounds/alarm.caf")
        } else {
            let fileURL = URL(fileURLWithPath: ringtone.excerptFileName)
            guard let bundledURL = Bundle.main.url(
                forResource: fileURL.deletingPathExtension().lastPathComponent,
                withExtension: fileURL.pathExtension
            ) else {
                return
            }
            url = bundledURL
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
