import AnimalPairsCore
import XCTest
@testable import AnimalPairs

/// Card flips play the generic flip or the revealed animal's own sound.
@MainActor
final class CardSoundTests: XCTestCase {
    /// A controllable clock so rapid-repeat protection does not drop test flips.
    private final class TestClock { var now: TimeInterval = 100 }

    private let animals: [CharacterID] = ["momo", "iris", "nori", "sprout", "mochi",
                                          "sunny", "maple", "clover", "rusty", "pebble"]

    /// A throwaway bundle with real, approved sound files copied under animal
    /// names: two Momo sounds, three Iris sounds and one Nori file that is too
    /// long to count as a short sound.
    private func makeSoundBundle() throws -> Bundle {
        let dir = AppTestSupport.temporaryDirectory()
        let copies = [
            "card_flip": "card_flip",
            "pair_match": "animal_momo_1", "card_close": "animal_momo_2",
            "hint": "animal_iris_1", "tap": "animal_iris_2", "button_tap": "animal_iris_purr",
            "completion_jingle": "animal_nori_long",
        ]
        for (source, target) in copies {
            let url = try XCTUnwrap(Bundle.main.url(forResource: source, withExtension: "wav"), source)
            try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent("\(target).wav"))
        }
        return try XCTUnwrap(Bundle(url: dir))
    }

    private func makeAudio(bundle: Bundle, clock: TestClock, seed: UInt64 = 7) -> AudioManager {
        let audio = AudioManager(isEnabled: true, voiceEnabled: false, bundle: bundle,
                                 clock: { clock.now }, randomSeed: seed)
        audio.loadAnimalSounds(for: animals)
        return audio
    }

    func testFindsOnlyUsableShortSoundsForEachAnimal() throws {
        let audio = makeAudio(bundle: try makeSoundBundle(), clock: TestClock())
        XCTAssertEqual(audio.animalLibrary.sounds(for: "momo"), ["animal_momo_1", "animal_momo_2"])
        XCTAssertEqual(audio.animalLibrary.sounds(for: "iris"), ["animal_iris_1", "animal_iris_2", "animal_iris_purr"])
        XCTAssertEqual(audio.animalLibrary.sounds(for: "nori"), [], "a 2.9 s file is not a short sound")
    }

    func testRepeatedFlipsAreVariedAndAlwaysMatchTheRevealedAnimal() throws {
        let clock = TestClock()
        let audio = makeAudio(bundle: try makeSoundBundle(), clock: clock)
        var heard: [CharacterID: Set<CardRevealSound>] = [:]
        for i in 0..<300 {
            clock.now += 0.5
            let animal: CharacterID = ["momo", "iris", "nori", "pebble"][i % 4]
            let sound = try XCTUnwrap(audio.playCardReveal(of: animal), "flip \(i) was silent")
            XCTAssertEqual(audio.lastCardReveal?.character, animal)
            if case .animal(let name) = sound {
                XCTAssertTrue(audio.animalLibrary.sounds(for: animal).contains(name), "\(name) played for \(animal)")
            }
            heard[animal, default: []].insert(sound)
        }
        XCTAssertEqual(heard["momo"], [.generic, .animal("animal_momo_1"), .animal("animal_momo_2")])
        XCTAssertEqual(heard["iris"], [.generic, .animal("animal_iris_1"), .animal("animal_iris_2"),
                                       .animal("animal_iris_purr")])
        XCTAssertEqual(heard["nori"], [.generic], "no usable Nori file: generic flip only")
        XCTAssertEqual(heard["pebble"], [.generic], "no Pebble file: generic flip only")
    }

    func testWithoutAnimalFilesEveryFlipUsesTheGenericSound() {
        let clock = TestClock()
        let audio = makeAudio(bundle: .main, clock: clock)
        for animal in animals {
            for _ in 0..<10 {
                clock.now += 0.5
                XCTAssertEqual(audio.playCardReveal(of: animal), .generic)
            }
        }
    }

    func testSoundOffSilencesAllCardAudio() throws {
        let clock = TestClock()
        let audio = makeAudio(bundle: try makeSoundBundle(), clock: clock)
        clock.now += 0.5
        XCTAssertNotNil(audio.playCardReveal(of: "iris"))
        audio.isEnabled = false
        XCTAssertFalse(audio.isCardSoundPlaying, "turning sound off stops the current card sound")
        for i in 0..<100 {
            clock.now += 0.5
            XCTAssertNil(audio.playCardReveal(of: i.isMultiple(of: 2) ? "momo" : "iris"))
            XCTAssertFalse(audio.isCardSoundPlaying)
        }
        audio.isEnabled = true
        clock.now += 0.5
        XCTAssertNotNil(audio.playCardReveal(of: "momo"))
    }

    func testRapidFlipsDoNotStack() throws {
        let clock = TestClock()
        let audio = makeAudio(bundle: try makeSoundBundle(), clock: clock)
        XCTAssertNotNil(audio.playCardReveal(of: "momo"))
        clock.now += 0.02
        XCTAssertNil(audio.playCardReveal(of: "iris"), "a second flip within 80 ms is dropped")
    }

    func testFlippingACardPlaysThatCardsAnimal() throws {
        let model = AppTestSupport.makeModel()
        try model.startNewGame(GameConfiguration(mode: .classic, boardSize: .six))
        let session = try XCTUnwrap(model.session)
        let tile = session.state.tiles[0]
        session.tap(tile.id)
        let expected = try XCTUnwrap(model.catalog.artwork(tile.pairKey)?.characterID)
        XCTAssertEqual(session.character(of: tile.id), expected)
        XCTAssertEqual(model.audio.lastCardReveal?.character, expected)
    }
}
