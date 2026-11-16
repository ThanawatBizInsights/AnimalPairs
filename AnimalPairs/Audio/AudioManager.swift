import AnimalPairsCore
import AVFoundation
import Foundation

/// Every sound effect the game can make. Raw values are bundled file names
/// (`<rawValue>.wav`). Only sounds approved in Tools/audio/audio_manifest.json
/// are bundled; until then an effect uses its fallbacks or stays silent.
/// The app never contacts ElevenLabs; it only plays these local files.
enum SoundEffect: String, CaseIterable {
    // Batch 1 (approved)
    case cardFlip = "card_flip"
    case cardClose = "card_close"
    case pairMatch = "pair_match"
    case pairMiss = "pair_miss"
    case boardComplete = "board_complete"
    case buttonTap = "button_tap"
    case gameStart = "game_start"
    case completionJingle = "completion_jingle"
    // Batch 2 (interface and rewards)
    case modeSelect = "mode_select"
    case back
    case pause
    case resume
    case starEarn = "star_earn"
    case badgeReveal = "badge_reveal"
    case perfectRound = "perfect_round"
    case confetti
    case hint
    case tryAgain = "try_again"
    case newBest = "new_best"
    // Batch 3 (one cue per animal; shared by its default, play and nap art)
    case animalMomo = "animal_momo"
    case animalIris = "animal_iris"
    case animalNori = "animal_nori"
    case animalSprout = "animal_sprout"
    case animalMochi = "animal_mochi"
    case animalSunny = "animal_sunny"
    case animalMaple = "animal_maple"
    case animalClover = "animal_clover"
    case animalRusty = "animal_rusty"
    case animalPebble = "animal_pebble"

    /// The animal's cue, used for all of its artwork poses.
    static func animal(_ character: CharacterID) -> SoundEffect? {
        SoundEffect(rawValue: "animal_\(character.rawValue)")
    }

    var isAnimalCue: Bool { rawValue.hasPrefix("animal_") }

    /// Files tried, in order, when this effect's own file is not bundled
    /// (not generated or not approved yet). Empty means silent until approved.
    var fallbackFiles: [String] {
        switch self {
        case .cardFlip, .cardClose: ["flip"]
        case .pairMatch, .gameStart: ["match"]
        case .pairMiss: ["mismatch"]
        case .boardComplete, .completionJingle: ["complete"]
        case .buttonTap: ["tap"]
        case .modeSelect, .back, .pause, .resume: ["button_tap", "tap"]
        case .perfectRound: ["board_complete", "complete"]
        case .hint: ["hint_synth"]
        case .starEarn, .badgeReveal, .confetti, .tryAgain, .newBest: []
        default: []  // animal cues
        }
    }

    /// Mix level relative to the master volume. Files are loudness-matched
    /// when generated; these only shape the mix.
    var mixVolume: Float {
        switch self {
        case .cardFlip: 0.8
        case .cardClose: 0.7
        case .pairMatch: 0.9
        case .pairMiss: 0.6
        case .boardComplete, .completionJingle, .perfectRound: 1.0
        case .buttonTap: 0.6
        case .modeSelect, .back: 0.7
        case .pause, .resume, .hint, .tryAgain: 0.75
        case .gameStart: 0.85
        case .starEarn: 0.85
        case .badgeReveal, .newBest: 0.9
        case .confetti: 0.45
        default: 0.8  // animal cues
        }
    }

    /// Shortest gap between two plays of this effect.
    var minInterval: TimeInterval {
        switch self {
        case .cardFlip: 0.08
        case .cardClose: 0.1
        case .buttonTap, .modeSelect: 0.12
        case .back: 0.15
        case .pairMatch: 0.2
        case .pairMiss, .hint, .pause, .resume, .starEarn: 0.3
        case .gameStart, .tryAgain: 0.5
        case .boardComplete, .perfectRound, .confetti, .badgeReveal, .newBest: 1.0
        case .completionJingle: 2.0
        default: 0.3  // animal cues
        }
    }

    /// Which sound keeps its voice when several overlap.
    var priority: Int {
        switch self {
        case .buttonTap, .modeSelect, .back: 0
        case .cardFlip, .cardClose, .pairMiss, .hint, .pause, .resume, .confetti, .tryAgain: 1
        case .pairMatch, .gameStart, .starEarn: 2
        case .boardComplete, .completionJingle, .perfectRound, .badgeReveal, .newBest: 3
        default: 2  // animal cues
        }
    }
}

/// Game moments that may produce an (occasional) spoken line.
enum NarrationEvent {
    case roundStarted, matched, missed, completed

    var cue: NarrationCue {
        switch self {
        case .roundStarted: .findPair
        case .matched: .greatMatch
        case .missed: .tryAgain
        case .completed: .allDone
        }
    }
}

/// Plays sound effects and narration from local files.
///
/// * Sound effects: one preloaded player per effect; the same sound restarts
///   instead of layering, rapid repeats are dropped and at most three effects
///   overlap (`SoundPlaybackPolicy`).
/// * Voice: a separate channel with its own saved switch. One line at a time,
///   chosen sparingly by `NarrationPolicy`; effects play quieter while a
///   line is spoken.
/// * Ambient audio session: respects the silent switch and the family's music.
/// * Delayed sounds are cancelled when a round is paused, restarted or left.
@MainActor
final class AudioManager {
    static let masterVolume: Float = 0.8
    static let voiceVolume: Float = 0.9
    /// Effects are reduced to this share of their level while a line is spoken.
    static let duckingFactor: Float = 0.5

    var isEnabled: Bool {
        didSet {
            if !isEnabled {
                cancelPending()
                stopEffects()
                policy.reset()
            }
        }
    }

    var voiceEnabled: Bool {
        didSet {
            if !voiceEnabled {
                cancelPending()
                voicePlayers.values.forEach { $0.stop() }
            }
        }
    }

    private var players: [SoundEffect: AVAudioPlayer] = [:]
    private var voicePlayers: [NarrationCue: AVAudioPlayer] = [:]
    /// The file each effect resolved to (its own file or a fallback).
    private(set) var resolvedFiles: [SoundEffect: String] = [:]
    private var policy = SoundPlaybackPolicy(maxVoices: 3)
    private var narration = NarrationPolicy()
    /// Gentle `try_again` cue after several misses in a row (never per miss).
    private var encouragement: NarrationPolicy = {
        var policy = NarrationPolicy()
        policy.matchesPerPraise = .max   // matches only reset the miss streak
        return policy
    }()
    private var pending: [Task<Void, Never>] = []
    private let clock: () -> TimeInterval

    init(isEnabled: Bool, voiceEnabled: Bool, bundle: Bundle = .main,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.isEnabled = isEnabled
        self.voiceEnabled = voiceEnabled
        self.clock = clock
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        for effect in SoundEffect.allCases {
            guard let (url, name) = Self.resource(for: effect, in: bundle),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.prepareToPlay()
            players[effect] = player
            resolvedFiles[effect] = name
        }
        for cue in NarrationCue.allCases {
            guard let url = Self.voiceURL(for: cue, in: bundle),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.volume = Self.voiceVolume
            player.prepareToPlay()
            voicePlayers[cue] = player
        }
    }

    // MARK: Introspection

    var loadedEffects: Set<SoundEffect> { Set(players.keys) }
    var loadedVoiceLines: Set<NarrationCue> { Set(voicePlayers.keys) }

    /// Effects playing a fallback (or nothing) because their own file is not bundled.
    var effectsUsingFallback: [SoundEffect] {
        SoundEffect.allCases.filter { resolvedFiles[$0]?.hasPrefix($0.rawValue + ".") != true }
    }

    var isSpeaking: Bool { voicePlayers.values.contains { $0.isPlaying } }

    // MARK: Effects

    func play(_ effect: SoundEffect) {
        guard isEnabled, let player = players[effect] else { return }
        let rule = SoundRule(minInterval: effect.minInterval, priority: effect.priority,
                             duration: max(player.duration, 0.05))
        switch policy.request(effect.rawValue, rule: rule, at: clock()) {
        case .skip:
            return
        case .restart:
            break
        case .play(let stopping):
            for name in stopping {
                if let other = SoundEffect(rawValue: name), let otherPlayer = players[other] {
                    otherPlayer.stop()
                    otherPlayer.currentTime = 0
                }
            }
        }
        player.volume = Self.masterVolume * effect.mixVolume * (isSpeaking ? Self.duckingFactor : 1)
        player.currentTime = 0
        player.play()
    }

    /// Plays after `delay` seconds unless cancelled first (see `cancelPending`).
    func play(_ effect: SoundEffect, after delay: TimeInterval) {
        schedule(after: delay) { [weak self] in self?.play(effect) }
    }

    /// The cue for a mismatch: usually `pair_miss`; after three misses in a
    /// row (at most every 20 s) the reassuring `try_again` instead.
    func missCue() -> SoundEffect {
        encouragement.missed(at: clock()) != nil ? .tryAgain : .pairMiss
    }

    /// A pair was matched: resets the miss streak.
    func noteMatch() {
        _ = encouragement.matched(at: clock())
    }

    // MARK: Voice

    /// Asks the narration policy whether this moment deserves a spoken line
    /// and, if so, schedules it. Returns true when a line was scheduled, so the
    /// caller can leave out an effect that would compete with it.
    @discardableResult
    func narrate(_ event: NarrationEvent, after delay: TimeInterval) -> Bool {
        guard voiceEnabled, voicePlayers[event.cue] != nil, !isSpeaking else { return false }
        let now = clock()
        let decision: NarrationCue?
        switch event {
        case .roundStarted: decision = narration.roundStarted(at: now)
        case .matched: decision = narration.matched(at: now)
        case .missed: decision = narration.missed(at: now)
        case .completed: decision = narration.completed(at: now)
        }
        guard let cue = decision else { return false }
        schedule(after: delay) { [weak self] in self?.speak(cue) }
        return true
    }

    private func speak(_ cue: NarrationCue) {
        guard voiceEnabled, let player = voicePlayers[cue], !isSpeaking else { return }
        player.currentTime = 0
        player.play()
    }

    // MARK: Lifecycle

    func cancelPending() {
        pending.forEach { $0.cancel() }
        pending.removeAll()
    }

    func stopAll() {
        stopEffects()
        voicePlayers.values.forEach { $0.stop() }
    }

    private func stopEffects() {
        for player in players.values {
            player.stop()
            player.currentTime = 0
        }
    }

    private func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        pending.removeAll { $0.isCancelled }
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            work()
        }
        pending.append(task)
    }

    private static func resource(for effect: SoundEffect, in bundle: Bundle) -> (URL, String)? {
        for ext in ["wav", "caf", "m4a"] {
            if let url = bundle.url(forResource: effect.rawValue, withExtension: ext) {
                return (url, "\(effect.rawValue).\(ext)")
            }
        }
        for name in effect.fallbackFiles {
            if let url = bundle.url(forResource: name, withExtension: "wav") {
                return (url, "\(name).wav")
            }
        }
        return nil
    }

    private static func voiceURL(for cue: NarrationCue, in bundle: Bundle) -> URL? {
        for ext in ["wav", "m4a", "mp3"] {
            if let url = bundle.url(forResource: "voice_\(cue.rawValue)", withExtension: ext) { return url }
        }
        return nil
    }
}
