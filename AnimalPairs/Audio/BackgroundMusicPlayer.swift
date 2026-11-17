import AnimalPairsCore
import AVFoundation
import Foundation

/// Background music: one persistent controller (owned by `AudioManager`,
/// which `AppModel` owns), one looping `AVAudioPlayer` per bundled track,
/// and at most one track wanted at a time (`MusicPolicy` picks it per scene).
///
/// * Gapless loops: the tracks are Apple Lossless `.caf` files cut on whole
///   bars, with no encoder delay, looped by `numberOfLoops = -1`.
/// * One current track. A new screen with the same track (Home → board choice
///   → game, a restarted round) changes nothing. A different track fades the
///   old one out (1 s) while the new one fades in (1.5 s).
/// * Background: paused immediately, keeping its position and the intention
///   to play. Foreground: the session is reactivated (off the main thread)
///   and the same player resumes from that position — unless Music is off,
///   another app is playing, or an interruption asked us not to resume.
/// * Interruptions: a phone call or alarm pauses the music; it resumes only
///   when the end of the interruption says it should (`shouldResume`),
///   otherwise at the next screen or foreground. iOS can report the app's own
///   suspension as an interruption that never "ends"; that is ignored here,
///   and becoming active always clears any stale interruption state.
/// * Route changes: headphones or Bluetooth disconnecting pause the music
///   (keeping its position) until the next screen or foreground.
/// * Failures are bounded: a track that cannot be loaded or played after one
///   rebuild is marked unavailable for this launch; session activation is
///   retried only at the next foreground, interruption end or media reset.
/// * The music never activates or deactivates the session itself (see
///   AudioSessionController), so short sound effects cannot silence it.
@MainActor
final class BackgroundMusicPlayer {
    /// Music level; well under the effects (master 0.8) so card sounds and
    /// animal clips stay clear.
    static let baseVolume: Float = 0.3
    static let fadeIn: TimeInterval = 1.5
    static let fadeOut: TimeInterval = 1.0
    static let quickFade: TimeInterval = 0.3
    /// Share of the music level while an animal clip plays.
    static let duckLevel: Float = 0.35
    static let duckAttack: TimeInterval = 0.15
    static let duckRelease: TimeInterval = 0.8

    let session: AudioSessionController
    private let bundle: Bundle
    private let scheduler: RoundScheduler
    private var players: [AnimalPairsMusicTrack: AVAudioPlayer] = [:]
    private var rebuilt: Set<AnimalPairsMusicTrack> = []
    private var failedTracks: Set<AnimalPairsMusicTrack> = []
    private var pendingStart: (track: AnimalPairsMusicTrack, work: ScheduledWork)?
    private var stopWork: [AnimalPairsMusicTrack: ScheduledWork] = [:]
    private var duckRestore: ScheduledWork?
    private var isDucked = false

    /// The track that is playing, or paused and resumable (position kept).
    private(set) var currentTrack: AnimalPairsMusicTrack?
    private(set) var scene: MusicScene = .silent
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            AudioDebugLog.note("music switched \(enabled ? "on" : "off")")
            update(fade: Self.quickFade)
        }
    }
    private(set) var appActive = true
    private(set) var interrupted = false
    private(set) var otherAudioPlaying = false
    private(set) var heldAfterRouteLoss = false
    private(set) var heldAfterInterruption = false

    /// `scheduler` and `session` default to nil and are created inside this
    /// @MainActor body (default arguments run outside the main actor in Swift 5).
    init(enabled: Bool, bundle: Bundle = .main, scheduler: RoundScheduler? = nil,
         session: AudioSessionController? = nil) {
        self.enabled = enabled
        self.bundle = bundle
        self.scheduler = scheduler ?? TaskRoundScheduler()
        self.session = session ?? AudioSessionController()
    }

    // MARK: State

    /// Tracks bundled with the app that loaded (a failed one is left out).
    var availableTracks: Set<AnimalPairsMusicTrack> {
        Set(AnimalPairsMusicTrack.allCases.filter { Self.url(for: $0, in: bundle) != nil && !failedTracks.contains($0) })
    }

    var isAudible: Bool {
        MusicPolicy.isAudible(enabled: enabled, appActive: appActive, interrupted: interrupted,
                              otherAudioPlaying: otherAudioPlaying,
                              heldAfterRouteLoss: heldAfterRouteLoss || heldAfterInterruption)
    }

    /// The track that should be heard now, if any.
    var wantedTrack: AnimalPairsMusicTrack? {
        guard isAudible, let track = MusicPolicy.track(for: scene), availableTracks.contains(track) else { return nil }
        return track
    }

    /// Tracks whose player is currently playing (more than one only while a
    /// previous track fades out).
    var playingTracks: [AnimalPairsMusicTrack] {
        players.filter { $0.value.isPlaying }.map(\.key)
    }

    /// The player of a track, if it has been created (tests, simulation).
    func player(of track: AnimalPairsMusicTrack) -> AVAudioPlayer? { players[track] }

    private var targetVolume: Float { Self.baseVolume * (isDucked ? Self.duckLevel : 1) }

    // MARK: Inputs

    func setScene(_ newScene: MusicScene) {
        if newScene != scene {
            heldAfterRouteLoss = false        // a new screen is a user action
            heldAfterInterruption = false
        }
        scene = newScene
        update(fade: Self.fadeOut)
    }

    /// Dips the music while an animal clip plays (`seconds` long), then restores it.
    func duck(for seconds: TimeInterval) {
        guard let track = currentTrack, let player = players[track], player.isPlaying else { return }
        isDucked = true
        player.setVolume(targetVolume, fadeDuration: Self.duckAttack)
        duckRestore?.cancel()
        duckRestore = scheduler.schedule(after: seconds) { [weak self] in
            guard let self else { return }
            self.isDucked = false
            if let track = self.currentTrack, let player = self.players[track], player.isPlaying {
                player.setVolume(self.targetVolume, fadeDuration: Self.duckRelease)
            }
        }
    }

    /// The session became active: start or resume whatever should play.
    func sessionDidActivate() {
        update(fade: Self.fadeOut)
    }

    func appDidEnterBackground() {
        appActive = false
        cancelPendingStart()
        // Pause at once (no fade: nothing is rendered in the background) and
        // keep the position; `currentTrack` remembers the intention to play.
        for (track, player) in players where player.isPlaying {
            player.pause()
            if track != currentTrack { player.currentTime = 0 }   // a fade-out in progress just ends
        }
        session.markInactive()
        AudioDebugLog.note("background: music paused at \(positionText)")
    }

    func appDidBecomeActive() {
        appActive = true
        // Stale states from while the app was away: a suspension reported as
        // an interruption never "ends", and returning is a user action.
        interrupted = false
        heldAfterInterruption = false
        heldAfterRouteLoss = false
        AudioDebugLog.note("foreground: restoring the session")
        session.activate { [weak self] in self?.update(fade: Self.fadeOut) }
    }

    /// An interruption began. `suspended`: iOS reports that the app itself was
    /// suspended (no matching "ended" will come) — handled by the foreground
    /// path instead.
    func interruptionBegan(suspended: Bool = false) {
        guard appActive, !suspended else {
            AudioDebugLog.note("interruption ignored (app suspended)")
            return
        }
        interrupted = true
        cancelPendingStart()
        session.markInactive()
        // The system has already paused the players; record it so a resume
        // continues from here.
        for player in players.values where player.isPlaying { player.pause() }
        AudioDebugLog.note("interruption began: music paused at \(positionText)")
    }

    /// An interruption ended. Resume only if the system says it should;
    /// otherwise wait for the next screen or foreground.
    func interruptionEnded(shouldResume: Bool = true) {
        guard interrupted else { return }
        interrupted = false
        guard shouldResume else {
            heldAfterInterruption = true
            AudioDebugLog.note("interruption ended without resume: waiting for the next screen")
            return
        }
        AudioDebugLog.note("interruption ended: resuming")
        session.activate { [weak self] in self?.update(fade: Self.fadeOut) }
    }

    /// Headphones or a Bluetooth device were disconnected: pause (keeping the
    /// position) until the next screen or until the app becomes active again.
    func outputDeviceRemoved() {
        heldAfterRouteLoss = true
        AudioDebugLog.note("audio route lost: music paused")
        update(fade: Self.quickFade)
    }

    /// Another app started or stopped playing audio.
    func otherAudioChanged(playing: Bool) {
        guard playing != otherAudioPlaying else { return }
        otherAudioPlaying = playing
        update(fade: Self.fadeOut)
    }

    /// The media server restarted: every player is invalid. Rebuild.
    func mediaServicesWereReset() {
        AudioDebugLog.note("media services reset: rebuilding music players")
        cancelPendingStart()
        stopWork.values.forEach { $0.cancel() }
        stopWork = [:]
        players = [:]
        rebuilt = []
        currentTrack = nil
        session.reset()
        session.activate { [weak self] in self?.update(fade: Self.fadeOut) }
    }

    // MARK: Core

    /// Brings playback in line with `wantedTrack`. Idempotent: called on every
    /// relevant change, it never starts a second player for the same track.
    private func update(fade: TimeInterval) {
        let wanted = wantedTrack
        if let pending = pendingStart, pending.track != wanted { cancelPendingStart() }

        if let current = currentTrack {
            if current == wanted {
                resume(current)
                return
            }
            if enabled, MusicPolicy.track(for: scene) == current {
                pause(current, fade: fade)       // blocked for now: keep the position
                return
            }
            fadeOutAndStop(current, fade: fade)
            currentTrack = nil
        }
        guard let wanted, pendingStart == nil else { return }
        let delay = MusicPolicy.startDelay(for: scene)
        if delay == 0 {
            begin(wanted)
        } else {
            let work = scheduler.schedule(after: delay) { [weak self] in
                self?.pendingStart = nil
                self?.begin(wanted)
            }
            pendingStart = (wanted, work)
        }
    }

    /// Makes `track` the current track and starts it from the beginning (or
    /// lets it continue if it is still fading out from a moment ago).
    private func begin(_ track: AnimalPairsMusicTrack) {
        guard wantedTrack == track, currentTrack == nil || currentTrack == track else { return }
        guard session.allowsPlayback else {
            session.activate { [weak self] in self?.update(fade: Self.fadeOut) }
            return
        }
        guard let player = player(for: track) else { return }
        stopWork[track]?.cancel()
        stopWork[track] = nil
        currentTrack = track
        if !player.isPlaying {
            player.currentTime = 0
            player.volume = 0
            guard start(player, track: track) else { return }
        }
        player.setVolume(targetVolume, fadeDuration: Self.fadeIn)
        AudioDebugLog.note("music started: \(track.rawValue)")
    }

    /// Continues the current track from its position (after background, an
    /// interruption, a route change…). Does nothing if it is already playing.
    private func resume(_ track: AnimalPairsMusicTrack) {
        stopWork[track]?.cancel()
        stopWork[track] = nil
        guard let player = players[track] else {
            currentTrack = nil
            begin(track)
            return
        }
        if player.isPlaying {
            player.setVolume(targetVolume, fadeDuration: Self.fadeIn)   // e.g. back from a fade-out
            return
        }
        guard session.allowsPlayback else {
            session.activate { [weak self] in self?.update(fade: Self.fadeOut) }
            return
        }
        player.volume = 0
        guard start(player, track: track) else { return }
        player.setVolume(targetVolume, fadeDuration: Self.fadeIn)
        AudioDebugLog.note("music resumed: \(track.rawValue) at \(positionText)")
    }

    /// `play()`, with one rebuild of the player if it fails; after that the
    /// track is unavailable for this launch (no endless retries).
    private func start(_ player: AVAudioPlayer, track: AnimalPairsMusicTrack) -> Bool {
        if player.play() { return true }
        AudioDebugLog.note("music play() failed: \(track.rawValue)")
        let position = player.currentTime
        players[track] = nil
        guard !rebuilt.contains(track), let fresh = self.player(for: track) else {
            markFailed(track)
            return false
        }
        rebuilt.insert(track)
        fresh.currentTime = position
        fresh.volume = 0
        if fresh.play() {
            AudioDebugLog.note("music recovered with a new player: \(track.rawValue)")
            return true
        }
        markFailed(track)
        return false
    }

    private func pause(_ track: AnimalPairsMusicTrack, fade: TimeInterval) {
        guard let player = players[track], player.isPlaying else { return }
        player.setVolume(0, fadeDuration: fade)
        stopWork[track]?.cancel()
        stopWork[track] = scheduler.schedule(after: fade) { [weak self] in
            guard let self, self.wantedTrack != track else { return }
            player.pause()                              // position kept
            self.stopWork[track] = nil
        }
    }

    private func fadeOutAndStop(_ track: AnimalPairsMusicTrack, fade: TimeInterval) {
        guard let player = players[track] else { return }
        guard player.isPlaying else {
            player.stop()
            player.currentTime = 0
            return
        }
        player.setVolume(0, fadeDuration: fade)
        stopWork[track]?.cancel()
        stopWork[track] = scheduler.schedule(after: fade) { [weak self] in
            guard let self, self.currentTrack != track else { return }
            player.stop()
            player.currentTime = 0
            self.stopWork[track] = nil
        }
    }

    private func cancelPendingStart() {
        pendingStart?.work.cancel()
        pendingStart = nil
    }

    /// The track's player, created once and kept for the app's lifetime.
    private func player(for track: AnimalPairsMusicTrack) -> AVAudioPlayer? {
        if let existing = players[track] { return existing }
        guard !failedTracks.contains(track), let url = Self.url(for: track, in: bundle) else { return nil }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1                   // seamless loop of the whole file
            player.volume = 0
            player.prepareToPlay()
            players[track] = player
            return player
        } catch {
            AudioDebugLog.note("music file could not be loaded: \(track.rawValue) (\(error.localizedDescription))")
            markFailed(track)
            return nil
        }
    }

    private func markFailed(_ track: AnimalPairsMusicTrack) {
        failedTracks.insert(track)
        players[track] = nil
        if currentTrack == track { currentTrack = nil }
        AudioDebugLog.note("music track disabled for this launch: \(track.rawValue)")
    }

    private var positionText: String {
        guard let track = currentTrack, let player = players[track] else { return "—" }
        return "\(track.rawValue) \(String(format: "%.1f", player.currentTime)) s"
    }

    // MARK: Files

    static func url(for track: AnimalPairsMusicTrack, in bundle: Bundle) -> URL? {
        bundle.url(forResource: track.rawValue, withExtension: "caf")
            ?? bundle.url(forResource: track.rawValue, withExtension: "caf", subdirectory: "Music")
    }
}
