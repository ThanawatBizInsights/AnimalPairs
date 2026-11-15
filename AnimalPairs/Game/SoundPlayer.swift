import AVFoundation
import Foundation

/// Plays the short, soft sound effects. Uses the ambient category so it
/// respects the silent switch and never interrupts the family's music.
@MainActor
final class SoundPlayer {
    enum Effect: String, CaseIterable {
        case flip, match, mismatch, hint, complete, tap
    }

    var isEnabled: Bool
    private var players: [Effect: AVAudioPlayer] = [:]

    init(isEnabled: Bool, bundle: Bundle = .main) {
        self.isEnabled = isEnabled
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        for effect in Effect.allCases {
            guard let url = bundle.url(forResource: effect.rawValue, withExtension: "wav"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.volume = 0.7
            player.prepareToPlay()
            players[effect] = player
        }
    }

    func play(_ effect: Effect) {
        guard isEnabled, let player = players[effect] else { return }
        player.currentTime = 0
        player.play()
    }
}
