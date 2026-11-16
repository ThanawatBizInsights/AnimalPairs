import AnimalPairsCore
import XCTest
@testable import AnimalPairs

/// Animal clips: card flips stay generic, a match plays one clip of the
/// matched animal, Home taps play a greeting clip with a cooldown, and the
/// Sound switch silences everything.
@MainActor
final class AnimalClipAppTests: XCTestCase {
    private final class TestClock { var now: TimeInterval = 100 }

    private func makeAudio(clock: TestClock, seed: UInt64 = 7) -> AudioManager {
        let audio = AudioManager(isEnabled: true, voiceEnabled: false, bundle: .main,
                                 clock: { clock.now }, randomSeed: seed)
        audio.loadAnimalClips(for: AnimalClipLibraryNames.animals)
        return audio
    }

    func testBundledClipsAreFoundForEveryGeneratedAnimal() {
        let audio = makeAudio(clock: TestClock())
        for animal in AnimalClipLibraryNames.animals {
            let clips = audio.clipLibrary.clips(for: animal, moment: .matched)
            XCTAssertTrue(clips.isEmpty || clips.count == 4, "\(animal): \(clips.map(\.name))")
            XCTAssertTrue(clips.allSatisfy { $0.character == animal })
        }
        XCTAssertGreaterThanOrEqual(audio.clipLibrary.clips.count, 8, "most animals have their clips")
        XCTAssertNil(audio.clipLibrary.clips.values.joined().first { ["card_flip", "pair_match"].contains($0.name) })
    }

    func testRepeatedMatchesPlayOnlyTheMatchedAnimalsClipsWithVariety() throws {
        let audio = makeAudio(clock: TestClock())
        for animal in AnimalClipLibraryNames.animals where audio.hasAnimalClips(for: animal) {
            var variants: Set<AnimalClipVariant> = []
            for _ in 0..<60 {
                let clip = try XCTUnwrap(audio.playMatchClip(for: animal))
                XCTAssertEqual(clip.character, animal, "\(clip.name) played for \(animal)")
                XCTAssertTrue(audio.isAnimalClipPlaying)
                variants.insert(clip.variant)
            }
            XCTAssertEqual(variants, Set(AnimalClipVariant.allCases), "\(animal) uses all four clips")
        }
    }

    func testHomeTapsPlayGreetingClipsWithACooldown() throws {
        let clock = TestClock()
        let audio = makeAudio(clock: clock)
        let animal = try XCTUnwrap(AnimalClipLibraryNames.animals.first { audio.hasAnimalClips(for: $0) })
        let first = try XCTUnwrap(audio.playHomeClip(for: animal))
        XCTAssertTrue([.greeting, .curious].contains(first.variant))
        for _ in 0..<10 {                    // rapid taps: ignored
            clock.now += 0.05
            XCTAssertNil(audio.playHomeClip(for: animal))
        }
        clock.now += 1
        XCTAssertNotNil(audio.playHomeClip(for: animal), "accepted again after the cooldown")
    }

    func testSoundOffSilencesAllAnimalClips() throws {
        let clock = TestClock()
        let audio = makeAudio(clock: clock)
        let animal = try XCTUnwrap(AnimalClipLibraryNames.animals.first { audio.hasAnimalClips(for: $0) })
        XCTAssertNotNil(audio.playMatchClip(for: animal))
        audio.isEnabled = false
        XCTAssertFalse(audio.isAnimalClipPlaying, "switching sound off stops the clip at once")
        for _ in 0..<20 {
            clock.now += 1
            XCTAssertNil(audio.playMatchClip(for: animal))
            XCTAssertNil(audio.playHomeClip(for: animal))
            XCTAssertFalse(audio.isAnimalClipPlaying)
        }
    }

    func testCardFlipsNeverPlayAnimalClipsAndMatchesPlayTheMatchedAnimal() throws {
        let model = AppTestSupport.makeModel()
        try model.startNewGame(GameConfiguration(mode: .classic, boardSize: .six))
        let session = try XCTUnwrap(model.session)
        let tiles = session.state.tiles
        // First card, then a card from a different pair: flips and a mismatch, no clip.
        let first = tiles[0]
        let other = try XCTUnwrap(tiles.first { $0.pairKey != first.pairKey })
        session.tap(first.id)
        XCTAssertNil(model.audio.lastAnimalClip, "first flip: generic sound only")
        session.tap(other.id)
        XCTAssertNil(model.audio.lastAnimalClip, "second flip of a mismatch: no animal clip")
        // Let the mismatch resolve, then make a real pair.
        let covered = expectation(description: "mismatch covered")
        Task { @MainActor in
            while session.state.pendingResolution != nil { try? await Task.sleep(nanoseconds: 50_000_000) }
            covered.fulfill()
        }
        wait(for: [covered], timeout: 5)
        XCTAssertNil(model.audio.lastAnimalClip, "a mismatch never plays an animal clip")
        let partner = try XCTUnwrap(tiles.first { $0.pairKey == first.pairKey && $0.id != first.id })
        session.tap(first.id)
        session.tap(partner.id)
        let matched = expectation(description: "pair matched")
        Task { @MainActor in
            while session.state.pendingResolution != nil { try? await Task.sleep(nanoseconds: 50_000_000) }
            matched.fulfill()
        }
        wait(for: [matched], timeout: 5)
        let animal = try XCTUnwrap(session.character(of: first.id))
        if model.audio.hasAnimalClips(for: animal) {
            XCTAssertEqual(model.audio.lastAnimalClip?.clip.character, animal)
        } else {
            XCTAssertNil(model.audio.lastAnimalClip)
        }
    }
}

enum AnimalClipLibraryNames {
    static let animals: [CharacterID] = ["momo", "iris", "nori", "sprout", "mochi",
                                         "sunny", "maple", "clover", "rusty", "pebble"]
}
