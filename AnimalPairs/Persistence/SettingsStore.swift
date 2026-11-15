import AnimalPairsCore
import Foundation
import Observation

/// Small, non-sensitive preferences. No personal data is stored.
@MainActor
@Observable
final class SettingsStore {
    private enum Key {
        static let sound = "settings.soundEnabled"
        static let language = "settings.language"
        static let mode = "settings.lastMode"
        static let board = "settings.lastBoard"
    }

    private let defaults: UserDefaults

    var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: Key.sound) } }
    var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: Key.language) } }
    var lastConfiguration: GameConfiguration {
        didSet {
            defaults.set(lastConfiguration.mode.rawValue, forKey: Key.mode)
            defaults.set(lastConfiguration.boardSize.rawValue, forKey: Key.board)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        soundEnabled = defaults.object(forKey: Key.sound) as? Bool ?? true
        language = defaults.string(forKey: Key.language).flatMap(AppLanguage.init(rawValue:)) ?? .system
        let mode = defaults.string(forKey: Key.mode).flatMap(GameMode.init(rawValue:)) ?? .classic
        let board = BoardSize(rawValue: defaults.integer(forKey: Key.board)) ?? .six
        lastConfiguration = GameConfiguration(mode: mode, boardSize: board)
    }
}
