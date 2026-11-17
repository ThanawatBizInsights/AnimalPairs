import Foundation

/// The four bundled background loops (`<rawValue>.m4a`).
public enum AnimalPairsMusicTrack: String, CaseIterable, Codable, Sendable {
    case playground = "music_playground"
    case meadow = "music_meadow"
    case focus = "music_focus"
    case celebration = "music_celebration"
}

/// Where the child is, as far as music is concerned.
public enum MusicScene: Equatable, Sendable {
    /// Home, Welcome and choosing a board.
    case menus
    /// Matching cards (including the pause menu).
    case game
    /// The results screen after a round.
    case results
    /// The grown-ups' area and its gate.
    case parents
    /// No music (the opening video plays its own sound).
    case silent
}

/// Which loop belongs where, and when music may be heard. Pure, so it is
/// tested on its own; `BackgroundMusicPlayer` (app) does the playing.
public enum MusicPolicy {
    /// Track for each scene. Home, choosing a board and playing share one
    /// loop, so moving between them never restarts the music.
    public static func track(for scene: MusicScene) -> AnimalPairsMusicTrack? {
        switch scene {
        case .menus: .playground
        case .game: .playground
        case .results: .celebration
        case .parents: .meadow
        case .silent: nil
        }
    }

    /// Seconds to wait before a scene's track fades in (the results jingle
    /// plays first; elsewhere music starts at once).
    public static func startDelay(for scene: MusicScene) -> TimeInterval {
        scene == .results ? 3.0 : 0
    }

    /// Music is heard only when every condition allows it.
    /// * `otherAudioPlaying`: another app (a parent's podcast or music) is
    ///   playing; background music stays silent rather than layering on it.
    /// * `heldAfterRouteLoss`: headphones were just unplugged; music waits
    ///   for the next screen or for the app to become active again.
    public static func isAudible(enabled: Bool, appActive: Bool, interrupted: Bool,
                                 otherAudioPlaying: Bool, heldAfterRouteLoss: Bool) -> Bool {
        enabled && appActive && !interrupted && !otherAudioPlaying && !heldAfterRouteLoss
    }
}
