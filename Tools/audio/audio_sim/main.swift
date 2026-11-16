// Linux simulation of Animal Pairs audio: real GameSession, RoundController
// and AudioManager playing many rounds on every board size, with the bundled
// sounds and animal clips. Checks:
//  * card flips (first and second card) only ever start card_flip;
//  * a mismatch starts no animal clip;
//  * every completed pair starts exactly one clip, of the matched animal;
//  * at most one animal clip plays at a time;
//  * with Sound off nothing starts at all;
//  * Home taps: greeting/curious of that animal, cooldown for rapid taps.
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
    let sounds = URL(fileURLWithPath: root).appendingPathComponent("AnimalPairs/Resources/Sounds")
    for case let file as URL in FileManager.default.enumerator(at: sounds, includingPropertiesForKeys: nil)!
    where ["wav", "m4a", "json"].contains(file.pathExtension) {
        try! FileManager.default.copyItem(at: file, to: bundleDir.appendingPathComponent(file.lastPathComponent))
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

    // Home: taps, rapid taps and switching animals.
    var accepted = 0, ignored = 0
    for i in 0..<300 {
        let animal = withClips[i % withClips.count]
        clock.now += (i % 5 == 0) ? 1.0 : 0.1          // bursts of rapid taps
        startedLog.removeAll()
        if let clip = audio.playHomeClip(for: animal) {
            accepted += 1
            check(clip.character == animal && [.greeting, .curious].contains(clip.variant), "home tap played \(clip.name)")
            check(startedLog == [clip.name], "home tap started \(startedLog)")
        } else {
            ignored += 1
            check(startedLog.isEmpty, "ignored tap started \(startedLog)")
        }
        check(clipPlayers().filter(\.isPlaying).count <= 1, "overlapping home clips")
    }
    print("home: 300 taps, \(accepted) played, \(ignored) ignored by the cooldown")
    check(accepted == 60, "one accepted tap per burst expected, got \(accepted)")
    audio.isEnabled = false
    check(audio.playHomeClip(for: withClips[0]) == nil && !audio.isAnimalClipPlaying, "home tap with sound off")

    print(failures == 0 ? "SIMULATION OK" : "SIMULATION FAILED: \(failures)")
    return failures == 0 ? 0 : 1
}
exit(MainActor.assumeIsolated { run() })
