import AnimalPairsCore
import AVFoundation
import Foundation

/// Background music: one looping track at a time, chosen by `MusicPolicy`
/// for the current scene.
///
/// * Gapless loops: each track is decoded once into memory and scheduled with
///   `.loops` on an `AVAudioPlayerNode`, so the join is sample-exact
///   (the loops were cut on whole bars with a crossfade when made).
/// * Two decks: switching scenes fades the old track out (1 s) while the new
///   one fades in (1.5 s). There are never more than these two nodes, so
///   navigation or restarting a round cannot create duplicate players; the
///   same scene again is a no-op and the music simply continues.
/// * Quiet by design (`baseVolume`), and dipped further by `MusicDuck` while
///   an animal clip plays.
/// * Loading happens off the main thread; gameplay never waits for music.
///   While a track decodes, its deck stays reserved (`front`) and silent.
/// * Lifecycle (see BackgroundMusicPlayer+Session.swift): paused in the background,
///   resumed when active, stopped for interruptions, held after headphones
///   are unplugged, silent while another app plays audio. The shared session
///   is `.ambient` + `.mixWithOthers`, so the Ring/Silent switch is respected
///   and other apps' audio is never stopped.
@MainActor
final class BackgroundMusicPlayer {
    /// Music level relative to full scale; well under the effects
    /// (master 0.8) so card sounds and animal clips stay clear.
    static let baseVolume: Float = 0.3
    static let fadeIn: TimeInterval = 1.5
    static let fadeOut: TimeInterval = 1.0
    /// Fade used when music must go quiet quickly (switched off, headphones out).
    static let quickFade: TimeInterval = 0.4
    static let tickInterval: TimeInterval = 1.0 / 30

    struct TrackInfo: Decodable { let frames: Int; let sampleRate: Double }

    private final class Deck {
        let node = AVAudioPlayerNode()
        var track: AnimalPairsMusicTrack?
        var ramp = VolumeRamp.steady(0)
        var isScheduled = false
        var token = 0
    }

    private let engine = AVAudioEngine()
    private let decks = [Deck(), Deck()]
    private var front: Deck?               // the deck holding the wanted track
    private var duckState = MusicDuck()
    private let clock: () -> TimeInterval
    private let bundle: Bundle
    private let index: [String: TrackInfo]
    private var buffers: [AnimalPairsMusicTrack: AVAudioPCMBuffer] = [:]
    private var nextToken = 0
    private var ticker: Task<Void, Never>?
    private var pendingStart: (track: AnimalPairsMusicTrack, at: TimeInterval)?

    /// Decodes a track and reports the result on the main actor. The app
    /// decodes on a background task; tests can decode inline or hold the
    /// completion to imitate a slow device.
    typealias Decoder = (_ url: URL, _ expectedFrames: Int,
                         _ done: @escaping @MainActor (MusicBuffer?) -> Void) -> Void
    var decode: Decoder = BackgroundMusicPlayer.decodeInBackground

    static let decodeInBackground: Decoder = { url, expected, done in
        Task.detached(priority: .utility) {
            let box = try? MusicBuffer(url: url, expectedFrames: expected)
            await MainActor.run { done(box) }
        }
    }

    static let decodeImmediately: Decoder = { url, expected, done in
        let box = try? MusicBuffer(url: url, expectedFrames: expected)
        MainActor.assumeIsolated { done(box) }
    }

    private(set) var scene: MusicScene = .silent
    var enabled: Bool { didSet { if enabled != oldValue { update(fade: Self.quickFade) } } }
    private(set) var appActive = true
    private(set) var interrupted = false
    private(set) var otherAudioPlaying = false
    private(set) var heldAfterRouteLoss = false

    /// The shared session: the engine only starts once it is active, so
    /// starting never activates the session implicitly on the main thread.
    let session: AudioSessionController
    /// Recent restarts after engine configuration changes (see
    /// `engineConfigurationChanged`); bounded so a change can never loop.
    private var configurationRestarts: [TimeInterval] = []
    static let maxConfigurationRestarts = 3
    static let configurationRestartWindow: TimeInterval = 10
    /// How often the engine was started (tests and diagnostics).
    private(set) var engineStarts = 0

    /// `session` defaults to nil and is created inside this @MainActor body
    /// (a main-actor initializer cannot run in a default argument).
    init(enabled: Bool, bundle: Bundle = .main,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         session: AudioSessionController? = nil) {
        self.enabled = enabled
        self.bundle = bundle
        self.clock = clock
        self.session = session ?? AudioSessionController()
        index = Self.loadIndex(bundle)
        for deck in decks { engine.attach(deck.node) }
    }

    /// The engine whose configuration-change notifications concern us.
    var engineForNotifications: AnyObject { engine }

    // MARK: State

    /// Tracks actually bundled with the app.
    var availableTracks: Set<AnimalPairsMusicTrack> {
        Set(AnimalPairsMusicTrack.allCases.filter { Self.url(for: $0, in: bundle) != nil })
    }

    var isAudible: Bool {
        MusicPolicy.isAudible(enabled: enabled, appActive: appActive, interrupted: interrupted,
                              otherAudioPlaying: otherAudioPlaying, heldAfterRouteLoss: heldAfterRouteLoss)
    }

    /// The track that should be heard now, if any.
    var wantedTrack: AnimalPairsMusicTrack? {
        guard isAudible, let track = MusicPolicy.track(for: scene), availableTracks.contains(track) else { return nil }
        return track
    }

    /// The track currently fading in or playing (nil while silent).
    var currentTrack: AnimalPairsMusicTrack? { front?.track }

    /// Decks currently producing sound (at most one outside a crossfade).
    var playingTracks: [AnimalPairsMusicTrack] {
        decks.filter { $0.node.isPlaying && $0.ramp.to > 0 }.compactMap(\.track)
    }

    /// The decks' current volumes, for tests and the simulation.
    var deckVolumes: [(track: AnimalPairsMusicTrack?, volume: Float, playing: Bool)] {
        decks.map { ($0.track, $0.node.volume, $0.node.isPlaying) }
    }

    // MARK: Inputs

    func setScene(_ newScene: MusicScene) {
        if newScene != scene { heldAfterRouteLoss = false; configurationRestarts = [] }
        scene = newScene
        update(fade: Self.fadeOut)
    }

    /// Dips the music while an animal clip plays (`seconds` long), then restores it.
    func duck(for seconds: TimeInterval) {
        let now = clock()
        duckState.duck(at: now, until: now + seconds)
        ensureTicking()
    }

    func appDidEnterBackground() {
        appActive = false
        pendingStart = nil
        engine.pause()           // keeps each deck's position; nothing renders in the background
        session.markInactive()   // the system deactivates it while the app is suspended
    }

    func appDidBecomeActive() {
        appActive = true
        heldAfterRouteLoss = false
        configurationRestarts = []
        // Reactivate the session off the main thread, then resume the paused
        // deck where it was (same player) or start the scene's track.
        session.activate { [weak self] in
            guard let self, self.appActive else { return }
            if self.decks.contains(where: { $0.track != nil && $0.isScheduled }) { self.startEngineIfNeeded() }
            self.update(fade: Self.fadeOut)
        }
    }

    func interruptionBegan() {
        interrupted = true
        pendingStart = nil
        session.markInactive()   // the system deactivated it
        stopAllDecks()           // and has already stopped the engine
    }

    func interruptionEnded() {
        interrupted = false
        // Reactivate (off the main thread), then resume.
        session.activate { [weak self] in self?.update(fade: Self.fadeOut) }
    }

    /// Headphones (or another output) were removed: go quiet until the next
    /// screen or until the app becomes active again.
    func outputDeviceRemoved() {
        heldAfterRouteLoss = true
        update(fade: Self.quickFade)
    }

    /// Another app started or stopped playing audio.
    func otherAudioChanged(playing: Bool) {
        otherAudioPlaying = playing
        update(fade: Self.fadeOut)
    }

    /// Our engine's configuration changed (e.g. the output route) and it
    /// stopped. Restart it and continue the current track on the same deck —
    /// no new player, no new session activation. Ignored when the engine is
    /// still running; at most `maxConfigurationRestarts` within
    /// `configurationRestartWindow`, so a change that keeps recurring can
    /// never turn into a restart loop (the next screen or foreground retries).
    func engineConfigurationChanged() {
        guard !engine.isRunning else { return }
        let now = clock()
        configurationRestarts = configurationRestarts.filter { now - $0 < Self.configurationRestartWindow }
        guard configurationRestarts.count < Self.maxConfigurationRestarts else { return }
        configurationRestarts.append(now)
        for deck in decks where deck !== front { reset(deck) }
        if !restartFrontIfStalled() { update(fade: Self.fadeOut) }
    }

    /// If the current track's deck has stopped (engine stopped by a
    /// configuration change or interruption), reschedule its decoded loop on
    /// the same deck and play it again. Returns false when there is no
    /// decoded current track to restart.
    @discardableResult
    private func restartFrontIfStalled() -> Bool {
        guard let front, let track = front.track, front.isScheduled else { return false }
        if engine.isRunning && front.node.isPlaying { return true }
        guard let buffer = buffers[track] else { return false }
        front.node.stop()
        front.node.scheduleBuffer(buffer, at: nil, options: .loops)
        guard startEngineIfNeeded() else { return true }     // continues in sessionDidActivate
        front.node.play()
        ensureTicking()
        return true
    }

    /// The session became active (launch, foreground, end of an
    /// interruption): start whatever has been waiting for it.
    func sessionDidActivate() {
        if let front, front.track == wantedTrack, restartFrontIfStalled() {
            front.ramp = front.ramp.retargeted(to: 1, at: clock(), duration: Self.fadeIn)
            ensureTicking()
            return
        }
        update(fade: Self.fadeOut)
    }

    // MARK: Core

    /// Brings the decks in line with `wantedTrack`.
    private func update(fade: TimeInterval) {
        let now = clock()
        let wanted = wantedTrack
        pendingStart = nil
        if let front, front.track == wanted, wanted != nil {
            // Same track: keep the same deck (never a second player); restart
            // it in place only if the engine stopped underneath it.
            restartFrontIfStalled()
            front.ramp = front.ramp.retargeted(to: 1, at: now, duration: Self.fadeIn)   // e.g. back from a dip-out
            ensureTicking()
            return
        }
        // Fade out whatever is playing.
        for deck in decks where deck.track != nil && deck.ramp.to > 0 {
            deck.ramp = deck.ramp.retargeted(to: 0, at: now, duration: fade)
        }
        front = nil
        if let wanted {
            let delay = MusicPolicy.startDelay(for: scene)
            pendingStart = (wanted, now + delay)
        }
        ensureTicking()
        tick(at: now)
    }

    private func start(_ track: AnimalPairsMusicTrack, at now: TimeInterval) {
        // Reuse a deck still fading out with the same track (quick back-and-forth).
        if let same = decks.first(where: { $0.track == track && $0.isScheduled }) {
            same.ramp = same.ramp.retargeted(to: 1, at: now, duration: Self.fadeIn)
            front = same
            startEngineIfNeeded()
            if !same.node.isPlaying { same.node.play() }
            return
        }
        // Otherwise the quieter deck (silent, or furthest into its fade-out).
        guard let deck = decks.min(by: { $0.ramp.value(at: now) < $1.ramp.value(at: now) }) else { return }
        reset(deck)
        nextToken += 1
        deck.token = nextToken
        deck.track = track
        deck.ramp = .steady(0)
        front = deck
        let token = deck.token
        if let buffer = buffers[track] {
            play(buffer, on: deck, at: now)
        } else if let url = Self.url(for: track, in: bundle) {
            // The deck waits (silent, marked `front`) until its track is decoded.
            decode(url, index[track.rawValue]?.frames ?? 0) { [weak self] box in
                guard let self, let box, deck.token == token, deck.track == track else { return }
                self.store(box.buffer, for: track)
                self.play(box.buffer, on: deck, at: self.clock())
            }
        }
    }

    private func play(_ buffer: AVAudioPCMBuffer, on deck: Deck, at now: TimeInterval) {
        guard front === deck, wantedTrack == deck.track else { return }   // superseded while loading
        engine.connect(deck.node, to: engine.mainMixerNode, format: buffer.format)
        deck.node.volume = 0
        deck.node.scheduleBuffer(buffer, at: nil, options: .loops)
        deck.isScheduled = true
        guard startEngineIfNeeded() else { return }
        deck.node.play()
        deck.ramp = VolumeRamp(from: 0, to: 1, start: now, duration: Self.fadeIn)
        ensureTicking()
    }

    private func store(_ buffer: AVAudioPCMBuffer, for track: AnimalPairsMusicTrack) {
        // Keep at most two decoded tracks (the ones on the decks).
        let onDecks = Set(decks.compactMap(\.track))
        buffers = buffers.filter { onDecks.contains($0.key) }
        buffers[track] = buffer
    }

    /// Starts the engine once the session is active. While it is not, asks
    /// the session controller to activate (off the main thread) and continues
    /// in `sessionDidActivate`. The engine then keeps running while music may
    /// play, so navigation and track changes never restart it.
    @discardableResult
    private func startEngineIfNeeded() -> Bool {
        guard appActive, !interrupted else { return false }
        if engine.isRunning { return true }
        guard session.allowsPlayback else {
            session.activate { [weak self] in self?.sessionDidActivate() }
            return false
        }
        do {
            try engine.start()
            engineStarts += 1
            return true
        } catch {
            return false
        }
    }

    private func reset(_ deck: Deck) {
        deck.node.stop()
        deck.track = nil
        deck.isScheduled = false
        deck.ramp = .steady(0)
        deck.node.volume = 0
    }

    private func stopAllDecks() {
        for deck in decks { reset(deck) }
        front = nil
        duckState.reset()
    }

    /// Applies fades and the duck at `now`; starts pending tracks; stops decks
    /// whose fade-out finished; pauses the engine when nothing plays.
    func tick(at now: TimeInterval) {
        if let pending = pendingStart, now >= pending.at {
            pendingStart = nil
            if wantedTrack == pending.track { start(pending.track, at: now) }
        }
        let duck = duckState.level(at: now)
        for deck in decks where deck.track != nil {
            let level = deck.ramp.value(at: now)
            deck.node.volume = Self.baseVolume * level * duck
            // Free a deck once its fade-out has finished. Never the front deck:
            // it may still be waiting (silent) for its track to be decoded.
            if deck !== front && deck.ramp.to == 0 && deck.ramp.isFinished(at: now) { reset(deck) }
        }
        // Pause only when music can't be heard at all (switched off, another
        // app playing…), not between tracks or screens.
        if !isAudible && decks.allSatisfy({ $0.track == nil }) && pendingStart == nil && engine.isRunning {
            engine.pause()
        }
    }

    private var needsTicking: Bool {
        pendingStart != nil || duckState.isActive(at: clock())
            || decks.contains { $0.track != nil && !$0.ramp.isFinished(at: clock()) }
            || decks.contains { $0 !== front && $0.track != nil && $0.ramp.to == 0 }
    }

    private func ensureTicking() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while let self, self.needsTicking {
                self.tick(at: self.clock())
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
            }
            if let self {
                self.tick(at: self.clock())
                self.ticker = nil
            }
        }
    }

    // MARK: Files

    static func url(for track: AnimalPairsMusicTrack, in bundle: Bundle) -> URL? {
        bundle.url(forResource: track.rawValue, withExtension: "m4a")
            ?? bundle.url(forResource: track.rawValue, withExtension: "m4a", subdirectory: "Music")
    }

    private static func loadIndex(_ bundle: Bundle) -> [String: TrackInfo] {
        struct Index: Decodable { let tracks: [String: TrackInfo] }
        guard let url = bundle.url(forResource: "music_tracks", withExtension: "json")
                ?? bundle.url(forResource: "music_tracks", withExtension: "json", subdirectory: "Music"),
              let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return [:] }
        return index.tracks
    }
}

/// A whole track decoded into memory, trimmed to its exact loop length.
/// Created off the main thread, then handed to the main actor.
final class MusicBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(url: URL, expectedFrames: Int) throws {
        let file = try AVAudioFile(forReading: url)
        guard let full = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                          frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: full)
        guard let range = LoopTrim.range(decodedFrames: Int(full.frameLength), expectedFrames: expectedFrames),
              let trimmed = AVAudioPCMBuffer(pcmFormat: full.format, frameCapacity: AVAudioFrameCount(range.count)),
              let source = full.floatChannelData, let target = trimmed.floatChannelData else {
            buffer = full
            return
        }
        for channel in 0..<Int(full.format.channelCount) {
            target[channel].update(from: source[channel].advanced(by: range.lowerBound), count: range.count)
        }
        trimmed.frameLength = AVAudioFrameCount(range.count)
        buffer = trimmed
    }
}
