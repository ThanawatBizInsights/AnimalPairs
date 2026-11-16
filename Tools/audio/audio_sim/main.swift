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

@MainActor func run() -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures += 1; print("FAIL:", message()) } }

    // A flat bundle like the app's: every bundled sound, clip and the clip index.
    let bundleDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sim-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
    for folder in ["Sounds", "Music"] {
        let dir = URL(fileURLWithPath: root).appendingPathComponent("AnimalPairs/Resources/\(folder)")
        for case let file as URL in FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        where ["wav", "m4a", "json"].contains(file.pathExtension) {
            try! FileManager.default.copyItem(at: file, to: bundleDir.appendingPathComponent(file.lastPathComponent))
        }
    }
    let bundle = Bundle(url: bundleDir)!
    let manifestData = try! Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("AnimalPairs/Resources/ArtworkManifest.json"))
    let manifest = try! JSONDecoder().decode(ArtworkManifest.self, from: manifestData)
    let catalog = ContentCatalog(manifest: manifest, installedAssets: Set(manifest.artworks.map(\.assetID)))
    let policy = ContentAccessPolicy(level: .fullGame)

    let clock = Clock()
    let audio = AudioManager(isEnabled: true, voiceEnabled: false, bundle: bundle, clock: { clock.now }, randomSeed: 11)
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

    playRounds(120, soundOn: true)
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

    // MARK: Background music
    audio.isEnabled = true
    let music = audio.music
    music.loadsInBackground = false
    let base = MusicPlayer.baseVolume
    func advance(_ seconds: Double, step: Double = 0.05) {
        var t = 0.0
        while t < seconds - 1e-9 { clock.now += step; t += step; music.tick(at: clock.now) }
    }
    func audibleTracks() -> [MusicTrack] { music.deckVolumes.filter { $0.playing && $0.volume > 0.001 }.compactMap(\.track) }
    check(music.availableTracks == Set(MusicTrack.allCases), "all four tracks bundled: \(music.availableTracks)")
    check(allPlayerNodes.count == 2, "two music decks, got \(allPlayerNodes.count)")

    // Off by default in this AudioManager (tests); switching on starts the menu loop.
    music.setScene(.menus)
    advance(1)
    check(audibleTracks().isEmpty, "music plays while the Music switch is off")
    audio.musicEnabled = true
    advance(0.5)
    check(music.currentTrack == .playground, "home starts music_playground")
    advance(1.5)
    check(audibleTracks() == [.playground], "only the home loop: \(audibleTracks())")
    let homeVolume = music.deckVolumes.first { $0.track == .playground }!.volume
    check(abs(homeVolume - base) < 0.001, "home loop at the base level, got \(homeVolume)")
    let node = allPlayerNodes.first { $0.isPlaying }!
    check(node.loops, "scheduled to loop")
    check(Int(node.scheduled!.frameLength) == 1_949_696, "loop trimmed to its exact length: \(node.scheduled!.frameLength)")
    check(node.scheduled!.floatChannelData![0][0] == 1, "trim starts at the first real sample")

    // Into a round: a soft crossfade to music_focus, never more than two decks.
    music.setScene(.game)
    var maxTogether = 0
    for _ in 0..<40 { advance(0.05); maxTogether = max(maxTogether, audibleTracks().count) }
    check(maxTogether <= 2, "more than two tracks at once")
    check(audibleTracks() == [.focus], "gameplay uses music_focus: \(audibleTracks())")
    let focusNode = allPlayerNodes.first { $0.isPlaying }!
    let playsBefore = focusNode.playCount
    music.setScene(.game)                                 // restarted round
    advance(1)
    check(focusNode.playCount == playsBefore && audibleTracks() == [.focus], "restart re-created the music")

    // Ducking under an animal clip, then a smooth return.
    let animal = withClips[0]
    _ = audio.playMatchClip(for: animal)
    advance(0.2)
    let ducked = music.deckVolumes.first { $0.track == .focus }!.volume
    check(ducked < base * 0.4, "music dips under the animal clip: \(ducked)")
    advance(4)
    let restored = music.deckVolumes.first { $0.track == .focus }!.volume
    check(abs(restored - base) < 0.001, "music restored after the clip: \(restored)")

    // Independent switches.
    audio.isEnabled = false
    advance(0.5)
    check(audibleTracks() == [.focus], "Sound Effects off must not stop the music")
    check(audio.playMatchClip(for: animal) == nil, "Sound Effects off silences animal clips")
    audio.isEnabled = true
    audio.musicEnabled = false
    advance(0.5)
    check(audibleTracks().isEmpty, "Music off fades the music out")
    startedLog.removeAll()
    audio.play(.cardFlip)
    check(startedLog == ["card_flip"], "Music off keeps sound effects: \(startedLog)")
    audio.musicEnabled = true
    advance(2)
    check(audibleTracks() == [.focus], "Music back on")

    // Results: the jingle first, music_celebration after 3 s.
    music.setScene(.results)
    advance(2)
    check(music.currentTrack == nil && !audibleTracks().contains(.celebration), "celebration waits for the jingle")
    advance(3)
    check(audibleTracks() == [.celebration], "results use music_celebration: \(audibleTracks())")

    // Background / active keeps one track and its position.
    music.setScene(.menus); advance(3)
    let homeNode = allPlayerNodes.first { $0.isPlaying && $0.volume > 0 }!
    let homePlays = homeNode.playCount
    music.appDidEnterBackground()
    music.appDidBecomeActive(); advance(1)
    check(audibleTracks() == [.playground] && homeNode.playCount == homePlays, "resumed without a new player")

    // Interruption (a phone call): stops, then resumes the scene's track.
    music.interruptionBegan()
    check(audibleTracks().isEmpty, "silent during an interruption")
    music.setScene(.game)                                  // navigation during the call
    advance(1)
    check(audibleTracks().isEmpty, "no music while interrupted")
    music.interruptionEnded(); advance(2)
    check(audibleTracks() == [.focus], "resumes with the current scene's track")

    // Headphones unplugged: quiet until the next screen.
    music.outputDeviceRemoved(); advance(1)
    check(audibleTracks().isEmpty, "music held after headphones were removed")
    music.setScene(.menus); advance(2)
    check(audibleTracks() == [.playground], "music returns on the next screen")

    // Another app playing audio: no music on top of it, and theirs is never stopped.
    music.otherAudioChanged(playing: true); advance(1.5)
    check(audibleTracks().isEmpty, "music stays silent while another app plays")
    music.otherAudioChanged(playing: false); advance(2)
    check(audibleTracks() == [.playground], "music back when the other app stops")

    // Opening video: silent.
    music.setScene(.silent); advance(1.5)
    check(audibleTracks().isEmpty, "no music during the opening video")

    // Stress: 500 random navigations and toggles never exceed two decks or leave strays.
    var rng = SeededGenerator(seed: 99)
    let scenes: [MusicScene] = [.menus, .game, .results, .parents, .silent]
    for i in 0..<500 {
        switch Int.random(in: 0..<10, using: &rng) {
        case 0: audio.musicEnabled.toggle()
        case 1: music.appDidEnterBackground(); music.appDidBecomeActive()
        case 2: _ = audio.playMatchClip(for: withClips[i % withClips.count])
        default: music.setScene(scenes.randomElement(using: &rng)!)
        }
        advance(Double(Int.random(in: 1...30, using: &rng)) * 0.05)
        check(audibleTracks().count <= 2, "step \(i): \(audibleTracks())")
    }
    audio.musicEnabled = true
    music.setScene(.game); advance(5)
    check(audibleTracks() == [.focus] && allPlayerNodes.filter(\.isPlaying).count == 1,
          "settles on exactly one track: \(audibleTracks())")
    check(allPlayerNodes.count == 2, "still only two decks after the stress run")
    print("music: \(Set(decodedFiles).sorted().joined(separator: ", ")) decoded; navigation, ducking, switches, lifecycle checked")

    print(failures == 0 ? "SIMULATION OK" : "SIMULATION FAILED: \(failures)")
    return failures == 0 ? 0 : 1
}
exit(MainActor.assumeIsolated { run() })
