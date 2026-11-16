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
    // Animal sounds are not effects: each card flip picks between `cardFlip`
    // and the revealed animal's own files (see `playCardReveal`).

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
        }
    }

    /// Which sound keeps its voice when several overlap.
    var priority: Int {
        switch self {
        case .buttonTap, .modeSelect, .back: 0
        case .cardFlip, .cardClose, .pairMiss, .hint, .pause, .resume, .confetti, .tryAgain: 1
        case .pairMatch, .gameStart, .starEarn: 2
        case .boardComplete, .completionJingle, .perfectRound, .badgeReveal, .newBest: 3
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
/// * Card flips: each flip plays either the generic flip or one of the
///   revealed animal's own bundled sounds (`animal_<id>[_<variant>]`), chosen
///   by `CardRevealSoundPicker`. One card sound at a time: a new flip replaces
///   the previous card's sound, and it is turned down under the match chime.
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
    private var pending: [Task<Void, Never>] = []
    private let clock: () -> TimeInterval

    /// Mix level of an animal's card sound (the generic flip uses `cardFlip`'s).
    static let animalMixVolume: Float = 0.75
    /// Card sound level while the match chime plays.
    static let cardSoundUnderMatch: Float = 0.4
    /// Longer files are not "short sounds" and are left out.
    static let maxAnimalSoundDuration: TimeInterval = 2.5
    /// Policy channel shared by every card-flip sound, generic or animal.
    static let cardRevealChannel = "card_reveal"
    private static let animalExtensions = ["wav", "caf", "m4a", "mp3"]

    private let bundle: Bundle
    private var animalPlayers: [String: AVAudioPlayer] = [:]
    private(set) var animalLibrary = AnimalSoundLibrary()
    private var revealPicker = CardRevealSoundPicker()
    private var revealRandom: SeededGenerator
    private weak var cardSoundPlayer: AVAudioPlayer?
    /// The last card sound that actually started, for tests and debugging.
    private(set) var lastCardReveal: (character: CharacterID?, sound: CardRevealSound)?

    init(isEnabled: Bool, voiceEnabled: Bool, bundle: Bundle = .main,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         randomSeed: UInt64 = UInt64.random(in: .min ... .max)) {
        self.isEnabled = isEnabled
        self.voiceEnabled = voiceEnabled
        self.clock = clock
        self.bundle = bundle
        revealRandom = SeededGenerator(seed: randomSeed)
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
            stopping.forEach(stopVoice)
        }
        player.volume = Self.masterVolume * effect.mixVolume * (isSpeaking ? Self.duckingFactor : 1)
        player.currentTime = 0
        player.play()
    }

    /// Plays after `delay` seconds unless cancelled first (see `cancelPending`).
    func play(_ effect: SoundEffect, after delay: TimeInterval) {
        schedule(after: delay) { [weak self] in self?.play(effect) }
    }

    // MARK: Card sounds

    /// Finds each animal's short sounds among the bundled files. Call once the
    /// characters are known; files that fail to load, are silent or are longer
    /// than `maxAnimalSoundDuration` are left out (that animal then uses the
    /// generic flip).
    func loadAnimalSounds(for characters: [CharacterID]) {
        animalPlayers.values.forEach { $0.stop() }
        animalPlayers = [:]
        var urls: [String: URL] = [:]
        for ext in Self.animalExtensions {
            for path in bundle.paths(forResourcesOfType: ext, inDirectory: nil) {
                let url = URL(fileURLWithPath: path)
                let name = url.deletingPathExtension().lastPathComponent
                if urls[name] == nil { urls[name] = url }
            }
        }
        let found = AnimalSoundLibrary(resourceNames: urls.keys, characters: characters)
        var usable: [CharacterID: [String]] = [:]
        for (character, names) in found.sounds {
            for name in names {
                guard let url = urls[name], let player = try? AVAudioPlayer(contentsOf: url),
                      player.duration > 0.05, player.duration <= Self.maxAnimalSoundDuration else { continue }
                player.prepareToPlay()
                animalPlayers[name] = player
                usable[character, default: []].append(name)
            }
        }
        animalLibrary = AnimalSoundLibrary(sounds: usable)
        revealPicker.reset()
    }

    /// Plays the sound for a card turning face up: the generic flip or one of
    /// the revealed animal's own sounds, picked at random. Never another
    /// animal's sound. Returns what started, or nil when sound is off or the
    /// flip came too quickly after the last one.
    @discardableResult
    func playCardReveal(of character: CharacterID?) -> CardRevealSound? {
        guard isEnabled else { return nil }
        var choice = revealPicker.pick(for: character, in: animalLibrary, using: &revealRandom)
        var player: AVAudioPlayer?
        var mix = SoundEffect.cardFlip.mixVolume
        if case .animal(let name) = choice, let own = animalPlayers[name] {
            player = own
            mix = Self.animalMixVolume
        } else {
            choice = .generic
            player = players[.cardFlip]
        }
        guard let player else { return nil }
        let rule = SoundRule(minInterval: SoundEffect.cardFlip.minInterval, priority: SoundEffect.cardFlip.priority,
                             duration: max(player.duration, 0.05))
        switch policy.request(Self.cardRevealChannel, rule: rule, at: clock()) {
        case .skip:
            return nil
        case .restart:
            break
        case .play(let stopping):
            stopping.forEach(stopVoice)
        }
        stopCardSound()
        player.volume = Self.masterVolume * mix * (isSpeaking ? Self.duckingFactor : 1)
        player.currentTime = 0
        player.play()
        cardSoundPlayer = player
        lastCardReveal = (character, choice)
        return choice
    }

    /// Seconds until the current card sound ends (0 when none is playing).
    var cardSoundRemaining: TimeInterval {
        guard let player = cardSoundPlayer, player.isPlaying else { return 0 }
        return max(0, player.duration - player.currentTime)
    }

    var isCardSoundPlaying: Bool { cardSoundPlayer?.isPlaying == true }

    /// Turns the card sound down so the match chime stays clear.
    func duckCardSound() {
        guard let player = cardSoundPlayer, player.isPlaying else { return }
        player.setVolume(player.volume * Self.cardSoundUnderMatch, fadeDuration: 0.12)
    }

    func stopCardSound() {
        cardSoundPlayer?.stop()
        cardSoundPlayer?.currentTime = 0
        cardSoundPlayer = nil
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
        for player in animalPlayers.values { player.stop() }
        cardSoundPlayer = nil
    }

    /// Stops the effect (or the card sound) a policy decision named.
    private func stopVoice(_ name: String) {
        if name == Self.cardRevealChannel {
            stopCardSound()
        } else if let effect = SoundEffect(rawValue: name), let player = players[effect] {
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
