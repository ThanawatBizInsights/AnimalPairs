import AnimalPairsCore
import Foundation
import Observation

/// Small, non-sensitive preferences. No personal data is stored.
@MainActor
@Observable
final class SettingsStore {
    private enum Key {
        static let sound = "settings.soundEnabled"
        static let voice = "settings.voiceEnabled"
        static let music = "settings.musicEnabled"
        static let muted = "settings.allSoundMuted"
        static let mode = "settings.lastMode"
        static let board = "settings.lastBoard"
        /// Retired: the first-launch Welcome page was removed. Deleted on launch.
        static let retiredWelcome = "settings.hasSeenWelcome"
    }

    private let defaults: UserDefaults

    /// "Sound effects" switch.
    var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: Key.sound) } }
    /// "Voice" switch (occasional narration), saved separately.
    var voiceEnabled: Bool { didSet { defaults.set(voiceEnabled, forKey: Key.voice) } }
    /// "Music" switch (background tracks), saved separately. On for a fresh
    /// install; a choice the family already made is kept (the key only exists
    /// once someone has set it).
    var musicEnabled: Bool { didSet { defaults.set(musicEnabled, forKey: Key.music) } }
    /// The speaker button on Home and the board: mutes every channel without
    /// changing the switches above, so unmuting restores them.
    var allSoundMuted: Bool { didSet { defaults.set(allSoundMuted, forKey: Key.muted) } }
    var lastConfiguration: GameConfiguration {
        didSet {
            defaults.set(lastConfiguration.mode.rawValue, forKey: Key.mode)
            defaults.set(lastConfiguration.boardSize.rawValue, forKey: Key.board)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        soundEnabled = defaults.object(forKey: Key.sound) as? Bool ?? true
        voiceEnabled = defaults.object(forKey: Key.voice) as? Bool ?? true
        musicEnabled = defaults.object(forKey: Key.music) as? Bool ?? true
        allSoundMuted = defaults.bool(forKey: Key.muted)
        let mode = defaults.string(forKey: Key.mode).flatMap(GameMode.init(rawValue:)) ?? .classic
        let board = BoardSize(rawValue: defaults.integer(forKey: Key.board)) ?? .six
        lastConfiguration = GameConfiguration(mode: mode, boardSize: board)
        defaults.removeObject(forKey: Key.retiredWelcome)
    }
}
