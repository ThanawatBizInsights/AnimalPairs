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
    // Animal clips (`<animal>_<variant>.m4a`) are not effects: see
    // `playAnimalClip` and `AnimalClipLibrary`.

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
/// * Animal clips: four per animal (`momo_greeting`, `momo_curious`, …).
///   Only a confirmed matched pair plays one of that animal's clips, cut short
///   at a natural pause (`matchEnd` in animal_clips.json). One clip at a time:
///   a new clip replaces the previous one. The music dips under each clip.
/// * Background music: `music` (`BackgroundMusicPlayer`), with its own Music switch.
///
/// * Sound effects: one preloaded player per effect; the same sound restarts
///   instead of layering, rapid repeats are dropped and at most three effects
///   overlap (`SoundPlaybackPolicy`).
/// * Voice: a separate channel with its own saved switch. One line at a time,
///   chosen sparingly by `NarrationPolicy`; effects play quieter while a
///   line is spoken.
/// * Ambient audio session (`.mixWithOthers`): respects the Ring/Silent switch
///   and never stops audio from other apps.
/// * The Sound Effects switch (`isEnabled`) covers cards, match, mismatch,
///   buttons and animal clips; the Music switch (`musicEnabled`) covers only
///   the background tracks.
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

    /// Mix level of the animal clips.
    static let animalClipVolume: Float = 0.85
    /// Effects that share the moment with an animal clip play at this share.
    static let levelUnderAnimalClip: Float = 0.6
    /// Matched-pair clips stop here when the clip index has no `matchEnd`.
    static let defaultMatchLength: TimeInterval = 2.0
    /// Fade at the end of a shortened clip.
    static let clipFadeOut: TimeInterval = 0.25
    private static let clipExtensions = ["m4a", "wav", "caf"]

    private let bundle: Bundle
    private var clipPlayers: [String: AVAudioPlayer] = [:]
    private var matchEnds: [String: TimeInterval] = [:]
    private(set) var clipLibrary = AnimalClipLibrary()
    private var clipPicker = AnimalClipPicker()
    private var clipRandom: SeededGenerator
    private var clipPlayer: AVAudioPlayer?
    private var clipStopTask: Task<Void, Never>?
    /// The last animal clip that started, and for which moment (tests, debugging).
    private(set) var lastAnimalClip: (clip: AnimalClip, moment: AnimalClipMoment)?

    /// Background music, one track at a time.
    let music: BackgroundMusicPlayer

    /// The Music switch: background tracks only.
    var musicEnabled: Bool {
        get { music.enabled }
        set { music.enabled = newValue }
    }

    /// The app's audio session (configured and activated once, off the main thread).
    let session: AudioSessionController

    init(isEnabled: Bool, voiceEnabled: Bool, musicEnabled: Bool = false, bundle: Bundle = .main,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         randomSeed: UInt64 = UInt64.random(in: .min ... .max),
         sessionController: AudioSessionController? = nil,
         musicScheduler: RoundScheduler? = nil) {
        self.isEnabled = isEnabled
        self.voiceEnabled = voiceEnabled
        self.clock = clock
        self.bundle = bundle
        clipRandom = SeededGenerator(seed: randomSeed)
        // One session controller for music and effects. It sets the category
        // and activates the session off the main thread (see AudioSessionController).
        let session = sessionController ?? AudioSessionController()
        self.session = session
        music = BackgroundMusicPlayer(enabled: musicEnabled, bundle: bundle, scheduler: musicScheduler, session: session)
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

    /// Plays an effect; `level` scales it (e.g. under an animal clip).
    func play(_ effect: SoundEffect, level: Float = 1) {
        guard isEnabled, let player = players[effect], sessionReady() else { return }
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
        player.volume = Self.masterVolume * effect.mixVolume * level * (isSpeaking ? Self.duckingFactor : 1)
        player.currentTime = 0
        player.play()
    }

    /// Plays after `delay` seconds unless cancelled first (see `cancelPending`).
    func play(_ effect: SoundEffect, after delay: TimeInterval) {
        schedule(after: delay) { [weak self] in self?.play(effect) }
    }

    // MARK: Animal clips

    /// Finds each animal's clips among the bundled files (`<animal>_<variant>`)
    /// and their matched-pair lengths from `animal_clips.json`. Files that fail
    /// to load or are silent are left out; that animal then plays no clip.
    func loadAnimalClips(for characters: [CharacterID]) {
        stopAnimalClip()
        clipPlayers = [:]
        var urls: [String: URL] = [:]
        // Xcode copies Sounds/Animals/ flat into the bundle; the subfolder is
        // also searched in case a build keeps the folder.
        for ext in Self.clipExtensions {
            for path in bundle.paths(forResourcesOfType: ext, inDirectory: nil)
                + bundle.paths(forResourcesOfType: ext, inDirectory: "Animals") {
                let url = URL(fileURLWithPath: path)
                let name = url.deletingPathExtension().lastPathComponent
                if urls[name] == nil { urls[name] = url }
            }
        }
        var usable: [AnimalClip] = []
        for clip in AnimalClipLibrary(resourceNames: urls.keys, characters: characters).clips.values.joined() {
            guard let url = urls[clip.name], let player = try? AVAudioPlayer(contentsOf: url),
                  player.duration > 0.3 else { continue }
            player.prepareToPlay()
            clipPlayers[clip.name] = player
            usable.append(clip)
        }
        clipLibrary = AnimalClipLibrary(clips: usable)
        matchEnds = Self.matchEnds(in: bundle)
        clipPicker.reset()
    }

    /// A matched pair: one of the matched animal's clips, chosen at random and
    /// stopped with a short fade at its natural pause (about 1–2 s). Returns the
    /// clip, or nil when sound is off or the animal has no clip.
    @discardableResult
    func playMatchClip(for character: CharacterID?) -> AnimalClip? {
        guard isEnabled, sessionReady(), let character,
              let clip = clipPicker.pick(for: character, moment: .matched, in: clipLibrary, using: &clipRandom)
        else { return nil }
        start(clip, moment: .matched, stopAfter: matchEnds[clip.name] ?? Self.defaultMatchLength)
        return clip
    }

    func hasAnimalClips(for character: CharacterID?) -> Bool {
        character.map { !clipLibrary.clips(for: $0, moment: .matched).isEmpty } ?? false
    }

    var isAnimalClipPlaying: Bool { clipPlayer?.isPlaying == true }

    /// Stops the current clip, at once or with a short fade.
    func stopAnimalClip(fadeDuration: TimeInterval = 0) {
        clipStopTask?.cancel()
        clipStopTask = nil
        guard let player = clipPlayer else { return }
        clipPlayer = nil
        guard fadeDuration > 0, player.isPlaying else {
            player.stop()
            return
        }
        player.setVolume(0, fadeDuration: fadeDuration)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(fadeDuration * 1_000_000_000))
            // Leave it alone if it was restarted as the new clip meanwhile.
            if self?.clipPlayer !== player { player.stop() }
        }
    }

    private func start(_ clip: AnimalClip, moment: AnimalClipMoment, stopAfter: TimeInterval?) {
        guard let player = clipPlayers[clip.name] else { return }
        stopAllClips()                     // one clip at a time, fading ones included
        player.volume = Self.masterVolume * Self.animalClipVolume * (isSpeaking ? Self.duckingFactor : 1)
        player.currentTime = 0
        player.play()
        clipPlayer = player
        lastAnimalClip = (clip, moment)
        // Let the animal be heard clearly: dip the music while it sounds.
        music.duck(for: min(stopAfter ?? player.duration, player.duration))
        if let stopAfter, stopAfter < player.duration {
            let fade = min(Self.clipFadeOut, stopAfter / 2)
            clipStopTask = Task { @MainActor [weak self, weak player] in
                try? await Task.sleep(nanoseconds: UInt64((stopAfter - fade) * 1_000_000_000))
                guard !Task.isCancelled, let self, let player, self.clipPlayer === player else { return }
                self.stopAnimalClip(fadeDuration: fade)
            }
        }
    }

    /// Stops every clip player, including one still fading out.
    private func stopAllClips() {
        clipStopTask?.cancel()
        clipStopTask = nil
        clipPlayer = nil
        for player in clipPlayers.values where player.isPlaying { player.stop() }
    }

    private static func matchEnds(in bundle: Bundle) -> [String: TimeInterval] {
        struct Index: Decodable {
            struct Clip: Decodable { let matchEnd: Double }
            let clips: [String: Clip]
        }
        guard let url = bundle.url(forResource: "animal_clips", withExtension: "json")
                ?? bundle.url(forResource: "animal_clips", withExtension: "json", subdirectory: "Animals"),
              let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return [:] }
        return index.clips.mapValues(\.matchEnd)
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
        guard voiceEnabled, let player = voicePlayers[cue], !isSpeaking, sessionReady() else { return }
        player.currentTime = 0
        player.play()
    }

    // MARK: Session and lifecycle

    /// A sound may start only once the session is active: `AVAudioPlayer.play()`
    /// would otherwise activate it implicitly on the main thread. Until then
    /// (the first moments after launch or after an interruption) the sound is
    /// skipped and activation is requested once, off the main thread.
    private func sessionReady() -> Bool {
        if session.allowsPlayback { return true }
        session.activate()
        return false
    }

    /// Launch: configure and activate the session once, off the main thread;
    /// music starts when it is active.
    func start() {
        session.activate { [weak self] in self?.music.sessionDidActivate() }
    }

    func appDidEnterBackground() {
        cancelPending()
        music.appDidEnterBackground()
    }

    func appDidBecomeActive() {
        music.appDidBecomeActive()
    }

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
        stopAllClips()
    }

    /// Stops the effect (or the card sound) a policy decision named.
    private func stopVoice(_ name: String) {
        if let effect = SoundEffect(rawValue: name), let player = players[effect] {
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
