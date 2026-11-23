// Linux simulation of Animal Pairs audio: real GameSession, RoundController
// and AudioManager playing many rounds on every board size, with the bundled
// sounds and animal clips. Checks:
//  * card flips (first and second card) only ever start card_flip;
//  * a mismatch starts no animal clip;
//  * every completed pair starts exactly one clip, of the matched animal;
//  * at most one animal clip plays at a time;
//  * with Sound off nothing starts at all;
//  * background music: one track per scene, crossfades, never more than the
//    two decks, ducking under animal clips, independent Music / Sound
//    Effects switches, background/active, interruptions, headphones removed,
//    other apps' audio, results delay, exact (trimmed) loop length.
import AnimalPairsCore
import AVFoundation
import Foundation

let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let animals: [CharacterID] = ["momo", "iris", "nori", "sprout", "mochi", "sunny", "maple", "clover", "rusty", "pebble"]

/// Runs scheduled round work only when asked.
@MainActor final class ManualScheduler: RoundScheduler {
    final class Work: ScheduledWork { var cancelled = false; let run: @MainActor () -> Void
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
        func cancel() { cancelled = true } }
    var queue: [Work] = []
    func schedule(after seconds: Double, _ work: @escaping @MainActor () -> Void) -> ScheduledWork {
        let item = Work(work); queue.append(item); return item
    }
    func runAll() { while !queue.isEmpty { let item = queue.removeFirst(); if !item.cancelled { item.run() } } }
}
final class Clock { var now = 100.0 }

/// Runs scheduled work when the simulated clock reaches it (music fades,
/// pauses after a fade, the results delay, the duck release).
@MainActor final class TimedScheduler: RoundScheduler {
    final class Work: ScheduledWork { var cancelled = false; let at: Double; let run: @MainActor () -> Void
        init(_ at: Double, _ run: @escaping @MainActor () -> Void) { self.at = at; self.run = run }
        func cancel() { cancelled = true } }
    let clock: Clock
    var queue: [Work] = []
    init(clock: Clock) { self.clock = clock }
    func schedule(after seconds: Double, _ work: @escaping @MainActor () -> Void) -> ScheduledWork {
        let item = Work(clock.now + seconds, work); queue.append(item); return item
    }
    func runDue() {
        while let next = queue.filter({ !$0.cancelled && $0.at <= clock.now }).min(by: { $0.at < $1.at }) {
            queue.removeAll { $0 === next }
            next.run()
        }
        queue.removeAll { $0.cancelled }
    }
}

@MainActor func run() -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures += 1; print("FAIL:", message()) } }

    // A flat bundle like the app's: every bundled sound, clip and the clip index.
    let bundleDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sim-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
    for folder in ["Sounds", "Music"] {
        let dir = URL(fileURLWithPath: root).appendingPathComponent("AnimalPairs/Resources/\(folder)")
        for case let file as URL in FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        where ["wav", "m4a", "caf", "json"].contains(file.pathExtension) {
            try! FileManager.default.copyItem(at: file, to: bundleDir.appendingPathComponent(file.lastPathComponent))
        }
    }
    let bundle = Bundle(url: bundleDir)!
    let manifestData = try! Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("AnimalPairs/Resources/ArtworkManifest.json"))
    let manifest = try! JSONDecoder().decode(ArtworkManifest.self, from: manifestData)
    let catalog = ContentCatalog(manifest: manifest, installedAssets: Set(manifest.artworks.map(\.assetID)))
    let policy = ContentAccessPolicy(level: .fullGame)

    let clock = Clock()
    // Session activation runs on a real background thread (as on iOS) but the
    // simulation waits for it, so results are deterministic.
    let threadRunner: AudioSessionController.Runner = { work, done in
        var ok = false
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread { ok = work(); finished.signal() }
        thread.start()
        finished.wait()
        done(ok)
    }
    let sessionController = AudioSessionController(runner: threadRunner)
    let musicScheduler = TimedScheduler(clock: clock)
    let audio = AudioManager(isEnabled: true, voiceEnabled: false, bundle: bundle, clock: { clock.now }, randomSeed: 11,
                             sessionController: sessionController, musicScheduler: musicScheduler)
    check(sessionActivations == 0, "nothing activates the session while the app is being set up")
    // Launch: AppModel.start() and the first `.active` scene phase.
    audio.start()
    audio.appDidBecomeActive()
    check(sessionActivations == 1, "one activation at launch, got \(sessionActivations)")
    check(sessionCategoryCalls == 1, "category set once, got \(sessionCategoryCalls)")
    audio.loadAnimalClips(for: animals)
    let clipNames = Set(audio.clipLibrary.clips.values.joined().map(\.name))
    let withClips = animals.filter { audio.hasAnimalClips(for: $0) }
    print("clips loaded: \(clipNames.count) for \(withClips.count) animals (\(withClips.map(\.rawValue).joined(separator: ", ")))")
    let clipPlayers = { allPlayers.filter { clipNames.contains($0.name) } }

    var heard: [CharacterID: [String: Int]] = [:]
    var flips = 0, mismatches = 0, matches = 0, silentMatches = 0
    var generator = SeededGenerator(seed: 2026)
    func playRounds(_ count: Int, soundOn: Bool) {
        audio.isEnabled = soundOn
        for round in 0..<count {
            let config = GameConfiguration(mode: round % 3 == 0 ? .exactPose : .classic,
                                           boardSize: BoardSize.allCases[round % BoardSize.allCases.count])
            guard let tiles = try? DeckBuilder.makeBoard(configuration: config, catalog: catalog, policy: policy, using: &generator)
            else { continue }
            let scheduler = ManualScheduler()
            let session = GameSession(state: RoundState(configuration: config, tiles: tiles), catalog: catalog,
                                      audio: audio, localizer: Localizer(host: bundle), scheduler: scheduler)
            var guardCount = 0
            while !session.state.isCompleted && guardCount < 400 {
                guardCount += 1
                let open = session.state.tiles.filter { $0.face == .covered }
                guard let first = open.randomElement(using: &generator) else { break }
                // Half the time pick its partner (a match), otherwise a random card.
                let partner = open.first { $0.pairKey == first.pairKey && $0.id != first.id }
                let second = Bool.random(using: &generator) ? partner! : open.filter { $0.id != first.id }.randomElement(using: &generator)!
                for tile in [first, second] {
                    clock.now += 0.4
                    startedLog.removeAll()
                    session.tap(tile.id)
                    // Rapid extra taps on the same and on a third card are ignored.
                    session.tap(tile.id)
                    flips += 1
                    check(startedLog.allSatisfy { $0 == "card_flip" }, "flip started \(startedLog)")
                    if !soundOn { check(startedLog.isEmpty, "sound off: flip started \(startedLog)") }
                }
                let isMatch = first.pairKey == second.pairKey
                let animal = session.character(of: first.id)!
                clock.now += 0.6
                startedLog.removeAll()
                scheduler.runAll()                    // resolve the pair
                let clips = startedLog.filter { clipNames.contains($0) }
                if !soundOn { check(startedLog.isEmpty, "sound off: resolution started \(startedLog)") }
                check(clipPlayers().filter(\.isPlaying).count <= 1, "more than one animal clip playing")
                if isMatch {
                    matches += 1
                    if soundOn && audio.hasAnimalClips(for: animal) {
                        check(clips.count == 1, "match of \(animal) started \(clips)")
                        if let clip = clips.first {
                            check(clip.hasPrefix(animal.rawValue + "_"), "\(clip) played for a \(animal) match")
                            heard[animal, default: [:]][clip, default: 0] += 1
                        }
                    } else {
                        check(clips.isEmpty, "no clip expected for \(animal), got \(clips)")
                        silentMatches += 1
                    }
                } else {
                    mismatches += 1
                    check(clips.isEmpty, "mismatch started an animal clip \(clips)")
                }
            }
            check(session.state.isCompleted, "round \(round) did not finish")
            session.end()
        }
    }

    let activationsBeforeRounds = sessionActivations
    playRounds(120, soundOn: true)
    check(sessionActivations == activationsBeforeRounds, "card flips / matches activated the session")
    print("sound on: \(flips) flips, \(mismatches) mismatches, \(matches) matches (\(silentMatches) for animals without clips)")
    for animal in withClips {
        let h = heard[animal] ?? [:]
        print("  \(animal.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) " +
              h.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: "  "))
        check(h.count == 4, "\(animal) should use all four clips, used \(h.count)")
    }

    flips = 0; matches = 0; mismatches = 0
    startedLog.removeAll()
    playRounds(30, soundOn: false)
    print("sound off: \(flips) flips, \(matches) matches, \(mismatches) mismatches, \(startedLog.count) sounds started")
    check(clipPlayers().allSatisfy { !$0.isPlaying }, "a clip kept playing with sound off")
    audio.isEnabled = true

    // Home animals no longer have a tap sound: there is no API for it any more.

    // MARK: Background music (AVAudioPlayer)
    audio.isEnabled = true
    let music = audio.music
    let base = BackgroundMusicPlayer.baseVolume
    func advance(_ seconds: Double, step: Double = 0.05) {
        var t = 0.0
        while t < seconds - 1e-9 { clock.now += step; t += step; musicScheduler.runDue() }
    }
    func musicPlayers(_ track: AnimalPairsMusicTrack) -> [AVAudioPlayer] { allPlayers.filter { $0.name == track.rawValue } }
    func plays(_ track: AnimalPairsMusicTrack) -> Int { startedLog.filter { $0 == track.rawValue }.count }
    func audible() -> [AnimalPairsMusicTrack] {
        AnimalPairsMusicTrack.allCases.filter { t in musicPlayers(t).contains { $0.isPlaying && $0.volume > 0.001 } }
    }
    startedLog.removeAll()
    check(music.availableTracks == Set(AnimalPairsMusicTrack.allCases), "all four tracks bundled: \(music.availableTracks)")

    // Switching Music on starts the Home loop.
    music.setScene(.menus); advance(1)
    check(audible().isEmpty, "music plays while the Music switch is off")
    audio.musicEnabled = true; advance(2)
    guard let home = music.player(of: .playground), home.isPlaying else {
        print("FAIL: no music is playing on Home"); print("SIMULATION FAILED"); return 1
    }
    check(home.numberOfLoops == -1, "the loop repeats forever")
    check(abs(home.volume - base) < 0.001, "music at its base level, got \(home.volume)")
    check(musicPlayers(.playground).count == 1, "one player for the Home loop")

    // Home → board choice → game → restarted round: same player, never restarted.
    let homePlays = plays(.playground)
    for scene in [MusicScene.menus, .game, .game, .menus, .game] {
        music.setScene(scene); advance(0.5)
        check(audible() == [.playground], "\(scene): \(audible())")
    }
    check(plays(.playground) == homePlays && music.player(of: .playground) === home, "navigation restarted the music")

    // The reported bug: switch apps and return, five times (with and without
    // iOS reporting the suspension as a never-ending interruption).
    let activations = sessionActivations
    for round in 1...5 {
        home.currentTime = 7.25 * Double(round)
        let position = home.currentTime
        audio.appDidEnterBackground()
        check(!home.isPlaying, "round \(round): paused in the background")
        music.interruptionBegan(suspended: round.isMultiple(of: 2))
        audio.appDidBecomeActive(); advance(2)
        check(home.isPlaying && audible() == [.playground], "round \(round): music did not resume")
        check(abs(home.currentTime - position) < 0.001, "round \(round): position lost")
        check(music.player(of: .playground) === home && musicPlayers(.playground).count == 1, "round \(round): a new player")
    }
    check(sessionActivations == activations + 5, "one session activation per return: \(sessionActivations - activations)")
    // The exact old failure: an interruption reported while still active, then
    // background, then foreground — no "ended" ever arrives.
    music.interruptionBegan()
    audio.appDidEnterBackground(); audio.appDidBecomeActive(); advance(2)
    check(home.isPlaying, "an interruption without an end kept the music off after returning")

    // Interruptions while in the app.
    home.currentTime = 20
    music.interruptionBegan()
    check(!home.isPlaying, "paused by an interruption")
    music.interruptionEnded(shouldResume: true); advance(2)
    check(home.isPlaying && abs(home.currentTime - 20) < 0.001, "resumes where it was when allowed")
    music.interruptionBegan(); music.interruptionEnded(shouldResume: false); advance(2)
    check(!home.isPlaying, "stays paused when the system says not to resume")
    music.setScene(.menus); advance(2)            // the next screen (game → Home)
    check(home.isPlaying, "resumes at the next screen")

    // Music off survives switching apps.
    audio.musicEnabled = false; advance(1)
    check(audible().isEmpty, "Music off silences the music")
    audio.appDidEnterBackground(); audio.appDidBecomeActive(); advance(2)
    check(audible().isEmpty && !home.isPlaying, "returning switched music back on")
    startedLog.removeAll(); audio.play(.cardFlip)
    check(startedLog == ["card_flip"], "sound effects still play with Music off")
    audio.musicEnabled = true; advance(2)
    check(audible() == [.playground], "Music back on")

    // Correct-pair animal sounds dip the music, which keeps playing.
    for i in 0..<20 {
        clock.now += 0.5
        _ = audio.playMatchClip(for: withClips[i % withClips.count])
        check(home.isPlaying && home.volume < base * 0.4, "music not dipped under an animal sound (\(home.volume))")
        advance(3)
        check(home.isPlaying && abs(home.volume - base) < 0.001, "music not restored after an animal sound (\(home.volume))")
    }

    // Headphones / Bluetooth disconnected: pause in place until the next screen.
    home.currentTime = 31
    music.outputDeviceRemoved(); advance(1)
    check(!home.isPlaying, "music paused when headphones went away")
    music.setScene(.game); advance(2)              // the next screen (Home → game)
    check(home.isPlaying && abs(home.currentTime - 31) < 0.001, "resumed in place on the next screen")

    // Another app playing: silent, then back.
    music.otherAudioChanged(playing: true); advance(1.5)
    check(audible().isEmpty, "music over another app's audio")
    music.otherAudioChanged(playing: false); advance(2)
    check(audible() == [.playground], "back when the other app stops")

    // Results: the jingle first, celebration after 3 s; back Home restarts the Home loop.
    music.setScene(.results); advance(2)
    check(!audible().contains(.celebration), "celebration waits for the jingle")
    advance(3)
    check(audible() == [.celebration], "results use music_celebration: \(audible())")
    music.setScene(.menus); advance(2)
    check(audible() == [.playground], "back to the Home loop: \(audible())")

    // A track that cannot play: one rebuild, then disabled — no endless retries.
    failToPlay = ["music_meadow"]; failedPlays.removeAll()
    for _ in 0..<5 { music.setScene(.parents); advance(1); music.setScene(.menus); advance(1) }
    check(failedPlays.count <= 2, "retried a failing track \(failedPlays.count) times")
    check(!music.availableTracks.contains(.meadow), "a failing track is disabled for this launch")
    check(audible() == [.playground], "other music still plays")
    failToPlay = []

    // Media services reset: players rebuilt, music back.
    music.mediaServicesWereReset(); advance(2)
    check(audible() == [.playground], "music after a media services reset")
    check(music.player(of: .playground) !== home, "the player was rebuilt")

    // Activation failure: bounded, sounds still try to play.
    let failing = AudioSessionController(runner: { _, done in done(false) })
    failing.activate()
    for _ in 0..<50 { _ = failing.allowsPlayback }
    check(failing.state == .failed && failing.allowsPlayback && failing.activationCount == 1,
          "a failed activation must not be retried on its own")

    // Stress: 500 random navigations, switches, matches and app switches.
    var rng = SeededGenerator(seed: 99)
    let scenes: [MusicScene] = [.menus, .game, .results, .parents, .silent]
    for i in 0..<500 {
        switch Int.random(in: 0..<10, using: &rng) {
        case 0: audio.musicEnabled.toggle()
        case 1: audio.appDidEnterBackground(); audio.appDidBecomeActive()
        case 2: _ = audio.playMatchClip(for: withClips[i % withClips.count])
        case 3: music.interruptionBegan(); music.interruptionEnded(shouldResume: Bool.random(using: &rng))
        default: music.setScene(scenes.randomElement(using: &rng)!)
        }
        advance(Double(Int.random(in: 1...30, using: &rng)) * 0.05)
        check(music.playingTracks.count <= 2, "step \(i): \(music.playingTracks)")
    }
    audio.musicEnabled = true
    music.setScene(.game); advance(4)
    check(audible() == [.playground] && music.playingTracks == [.playground], "settles on one track: \(music.playingTracks)")
    check(sessionMainThreadActivations == 0, "\(sessionMainThreadActivations) activations on the main thread")
    // MARK: Speaker button (master mute)
    music.setScene(.game); advance(4)
    _ = audio.playMatchClip(for: withClips[0])
    check(clipPlayers().contains { $0.isPlaying }, "a clip is playing before muting")
    audio.isMuted = true
    check(clipPlayers().allSatisfy { !$0.isPlaying }, "muting stops the playing animal clip")
    startedLog.removeAll()
    for effect in SoundEffect.allCases { audio.play(effect) }
    check(audio.playMatchClip(for: withClips[1]) == nil, "no animal clip while muted")
    check(startedLog.isEmpty, "muted: sounds started \(startedLog)")
    advance(3)
    // Only the players the music player owns count: a player it replaced
    // earlier is released in the app (the stand-in keeps it in `allPlayers`).
    check(music.playingTracks.isEmpty && music.currentTrack == nil, "music still playing while muted: \(music.playingTracks)")
    check(audio.musicEnabled && audio.isEnabled, "muting keeps the Music and Sound Effects switches")
    audio.appDidEnterBackground(); audio.appDidBecomeActive(); advance(2)
    check(music.playingTracks.isEmpty, "an app switch does not bring music back while muted: \(music.playingTracks)")
    audio.isMuted = false
    advance(4)
    check(music.playingTracks == [.playground] && (music.player(of: .playground)?.volume ?? 0) > 0.001,
          "unmuting restores the music: \(music.playingTracks)")
    audio.play(SoundEffect.allCases[0])
    check(!startedLog.isEmpty, "unmuting restores sound effects")
    print("mute: clip stopped, effects, clips and music silent (also across an app switch); unmute restored them")

    print("music: Home loop resumed after 5 app switches at the same position; navigation, interruptions, "
          + "route loss, Music off, 20 animal-sound dips, failures and 500 random steps checked")

    print(failures == 0 ? "SIMULATION OK" : "SIMULATION FAILED: \(failures)")
    return failures == 0 ? 0 : 1
}
exit(MainActor.assumeIsolated { run() })
