// Drives the real AudioManager: repeated flips for all ten animals.
import AnimalPairsCore
import AVFoundation
import Foundation

let animals: [CharacterID] = ["momo", "iris", "nori", "sprout", "mochi", "sunny", "maple", "clover", "rusty", "pebble"]
let sounds = "/work/AnimalPairs/Resources/Sounds"

func bundle(_ copies: [(String, String)]) -> Bundle {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sim-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (src, dst) in copies {
        try! FileManager.default.copyItem(atPath: "\(sounds)/\(src).wav", toPath: dir.appendingPathComponent("\(dst).wav").path)
    }
    return Bundle(url: dir)!
}

@MainActor func run() {
    var failures = 0
    func check(_ ok: Bool, _ msg: String) { if !ok { failures += 1; print("FAIL:", msg) } }
    final class Clock { var now = 100.0 }

    // 1. The real bundle today: no animal files, every flip generic.
    let real = bundle(try! FileManager.default.contentsOfDirectory(atPath: sounds)
        .filter { $0.hasSuffix(".wav") }.map { String($0.dropLast(4)) }.map { ($0, $0) })
    var clock = Clock()
    var audio = AudioManager(isEnabled: true, voiceEnabled: false, bundle: real, clock: { clock.now }, randomSeed: 1)
    audio.loadAnimalSounds(for: animals)
    check(audio.animalLibrary.sounds.isEmpty, "current bundle has no animal sounds")
    var generic = 0
    for i in 0..<500 { clock.now += 0.4; if audio.playCardReveal(of: animals[i % 10]) == .generic { generic += 1 } }
    print("current bundle: \(generic)/500 flips generic card_flip")
    check(generic == 500, "all flips generic")

    // 2. Every animal with 2-3 short files (real sounds copied under animal names) + one too-long file.
    let shortSources = ["pair_match", "card_close", "hint", "button_tap", "back", "resume", "pause", "mode_select",
                        "try_again", "star_earn", "game_start", "pair_miss", "tap", "badge_reveal", "new_best",
                        "confetti", "hint_synth", "flip", "match", "mismatch", "perfect_round", "board_complete", "complete"]
    var copies: [(String, String)] = [("card_flip", "card_flip"), ("completion_jingle", "animal_pebble_long")]
    var expected: [CharacterID: Set<String>] = [:]
    var k = 0
    for (n, a) in animals.enumerated() {
        for v in 1...(n % 2 == 0 ? 3 : 2) {
            let src = shortSources[k % shortSources.count]; k += 1
            let name = "animal_\(a.rawValue)_\(v)"
            copies.append((src, name))
            expected[a, default: []].insert(name)
        }
    }
    let full = bundle(copies)
    clock = Clock()
    audio = AudioManager(isEnabled: true, voiceEnabled: false, bundle: full, clock: { clock.now }, randomSeed: 42)
    audio.loadAnimalSounds(for: animals)
    for a in animals {
        let found = Set(audio.animalLibrary.sounds(for: a))
        let want = expected[a, default: []].filter { name in
            (try? AVAudioPlayer(contentsOf: full.url(forResource: name, withExtension: "wav")!)).map { $0.duration <= 2.5 } ?? false }
        check(found == want, "\(a) library \(found.sorted()) vs \(want.sorted())")
    }
    check(audio.animalLibrary.sounds(for: "pebble").allSatisfy { !$0.contains("long") }, "long file excluded")
    var heard: [CharacterID: [String: Int]] = [:]
    var wrong = 0, played = 0
    for i in 0..<4000 {
        clock.now += 0.4
        let a = animals[(i * 3 + i / 10) % 10]
        audibleLog.removeAll()
        guard let s = audio.playCardReveal(of: a) else { check(false, "flip \(i) silent"); continue }
        played += 1
        let file = audibleLog.last ?? "?"
        switch s {
        case .generic: check(file == "card_flip", "generic played \(file)"); heard[a, default: [:]]["card_flip", default: 0] += 1
        case .animal(let n):
            if !audio.animalLibrary.sounds(for: a).contains(n) || file != n { wrong += 1 }
            heard[a, default: [:]][n, default: 0] += 1
        }
        check(audio.isCardSoundPlaying, "card sound playing after flip")
    }
    print("4000 flips: \(played) played, \(wrong) wrong-animal sounds")
    check(wrong == 0, "no wrong-animal sounds")
    for a in animals {
        let h = heard[a] ?? [:]
        let lib = audio.animalLibrary.sounds(for: a)
        print("  \(a.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))", h.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: "  "))
        check(Set(h.keys) == Set(["card_flip"] + lib), "\(a) heard every option")
    }

    // 3. Sound off silences all card audio, at once and for later flips.
    clock.now += 0.4; audio.playCardReveal(of: "iris")
    audio.isEnabled = false
    check(!audio.isCardSoundPlaying, "switching off stops the current card sound")
    audibleLog.removeAll()
    for i in 0..<500 { clock.now += 0.4; check(audio.playCardReveal(of: animals[i % 10]) == nil, "silent when off") }
    print("sound off: 500 flips, \(audibleLog.count) sounds started")
    check(audibleLog.isEmpty, "nothing audible while off")
    audio.isEnabled = true; clock.now += 0.4
    check(audio.playCardReveal(of: "momo") != nil, "sound back on")

    // 4. Rapid double flip does not stack; one card sound at a time.
    clock.now += 0.4; audio.playCardReveal(of: "momo")
    clock.now += 0.02
    check(audio.playCardReveal(of: "iris") == nil, "flip within 80 ms dropped")
    print(failures == 0 ? "SIMULATION OK" : "SIMULATION FAILED: \(failures)")
    exit(failures == 0 ? 0 : 1)
}
MainActor.assumeIsolated { run() }
