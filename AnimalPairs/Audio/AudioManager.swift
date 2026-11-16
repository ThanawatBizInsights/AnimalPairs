import AnimalPairsCore
import AVFoundation
import Foundation

/// Every sound the game can make. Raw values are the bundled file names
/// (`<rawValue>.wav`), produced offline by Tools/audio/generate_elevenlabs_sfx.py.
/// The app never contacts ElevenLabs; it only plays these local files.
enum SoundEffect: String, CaseIterable {
    case cardFlip = "card_flip"
    case cardClose = "card_close"
    case pairMatch = "pair_match"
    case pairMiss = "pair_miss"
    case boardComplete = "board_complete"
    case buttonTap = "button_tap"
    case gameStart = "game_start"
    case completionJingle = "completion_jingle"
    /// Not part of the first ElevenLabs batch; uses the synthesized sound.
    case hint

    /// Synthesized development sound used until the generated file is bundled.
    var fallbackResource: String {
        switch self {
        case .cardFlip, .cardClose: "flip"
        case .pairMatch, .gameStart: "match"
        case .pairMiss: "mismatch"
        case .boardComplete, .completionJingle: "complete"
        case .buttonTap: "tap"
        case .hint: "hint"
        }
    }

    /// Mix level relative to the master volume. Files are loudness-matched
    /// when generated; these only shape the mix (e.g. a quieter miss).
    var mixVolume: Float {
        switch self {
        case .cardFlip: 0.8
        case .cardClose: 0.7
        case .pairMatch: 0.9
        case .pairMiss: 0.6
        case .boardComplete, .completionJingle: 1.0
        case .buttonTap: 0.6
        case .gameStart: 0.85
        case .hint: 0.7
        }
    }

    /// Shortest gap between two plays of this effect.
    var minInterval: TimeInterval {
        switch self {
        case .cardFlip: 0.08
        case .cardClose: 0.1
        case .buttonTap: 0.12
        case .pairMatch: 0.2
        case .pairMiss, .hint: 0.3
        case .gameStart: 0.5
        case .boardComplete: 1.0
        case .completionJingle: 2.0
        }
    }

    /// Which sound keeps its voice when several overlap.
    var priority: Int {
        switch self {
        case .buttonTap: 0
        case .cardFlip, .cardClose, .pairMiss, .hint: 1
        case .pairMatch, .gameStart: 2
        case .boardComplete, .completionJingle: 3
        }
    }
}

/// Plays sound effects from local files with anti-stacking rules.
///
/// * One preloaded player per effect: the same sound restarts instead of
///   layering, and rapid repeats are dropped (`SoundPlaybackPolicy`).
/// * At most three different effects overlap; lower-priority sounds yield.
/// * Uses the ambient audio session, so the silent switch is respected and
///   the family's own music is never interrupted.
/// * Delayed sounds can be cancelled when a round is paused or left.
@MainActor
final class AudioManager {
    static let masterVolume: Float = 0.8

    var isEnabled: Bool {
        didSet {
            if !isEnabled {
                cancelPending()
                stopAll()
                policy.reset()
            }
        }
    }

    private var players: [SoundEffect: AVAudioPlayer] = [:]
    /// The file each effect resolved to (generated file or fallback).
    private(set) var resolvedFiles: [SoundEffect: String] = [:]
    private var policy = SoundPlaybackPolicy(maxVoices: 3)
    private var pending: [Task<Void, Never>] = []
    private let clock: () -> TimeInterval

    init(isEnabled: Bool, bundle: Bundle = .main,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.isEnabled = isEnabled
        self.clock = clock
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        for effect in SoundEffect.allCases {
            guard let (url, name) = Self.resource(for: effect, in: bundle),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.volume = Self.masterVolume * effect.mixVolume
            player.prepareToPlay()
            players[effect] = player
            resolvedFiles[effect] = name
        }
    }

    /// Effects still using a synthesized development fallback.
    var effectsUsingFallback: [SoundEffect] {
        SoundEffect.allCases.filter { effect in
            resolvedFiles[effect]?.hasPrefix(effect.rawValue + ".") != true
        }
    }

    var loadedEffects: Set<SoundEffect> { Set(players.keys) }

    func play(_ effect: SoundEffect) {
        guard isEnabled, let player = players[effect] else { return }
        let rule = SoundRule(minInterval: effect.minInterval, priority: effect.priority,
                             duration: max(player.duration, 0.05))
        switch policy.request(effect.rawValue, rule: rule, at: clock()) {
        case .skip:
            return
        case .restart:
            player.currentTime = 0
            player.play()
        case .play(let stopping):
            for name in stopping {
                if let other = SoundEffect(rawValue: name), let otherPlayer = players[other] {
                    otherPlayer.stop()
                    otherPlayer.currentTime = 0
                }
            }
            player.currentTime = 0
            player.play()
        }
    }

    /// Plays after `delay` seconds unless cancelled first (see `cancelPending`).
    func play(_ effect: SoundEffect, after delay: TimeInterval) {
        pending.removeAll { $0.isCancelled }
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.play(effect)
        }
        pending.append(task)
    }

    func cancelPending() {
        pending.forEach { $0.cancel() }
        pending.removeAll()
    }

    func stopAll() {
        for player in players.values {
            player.stop()
            player.currentTime = 0
        }
    }

    private static func resource(for effect: SoundEffect, in bundle: Bundle) -> (URL, String)? {
        for ext in ["wav", "caf", "m4a"] {
            if let url = bundle.url(forResource: effect.rawValue, withExtension: ext) {
                return (url, "\(effect.rawValue).\(ext)")
            }
        }
        if let url = bundle.url(forResource: effect.fallbackResource, withExtension: "wav") {
            return (url, "\(effect.fallbackResource).wav")
        }
        return nil
    }
}
