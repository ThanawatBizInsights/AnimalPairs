@testable import AnimalPairsCore
import XCTest

final class AnimalSoundLibraryTests: XCTestCase {
    static let animals: [CharacterID] = ["momo", "iris", "nori", "sprout", "mochi",
                                         "sunny", "maple", "clover", "rusty", "pebble"]

    func testFindsEachAnimalsOwnFilesOnly() {
        let library = AnimalSoundLibrary(resourceNames: [
            "animal_momo", "animal_momo_2", "animal_momo_purr", "animal_iris_1",
            "card_flip", "pair_match", "animal_momox", "animal_", "animal_iris_", "animal_unknown_1",
            "voice_find_pair", "animal_iris_\u{00E9}t\u{00E9}",
        ], characters: Self.animals)
        XCTAssertEqual(library.sounds(for: "momo"), ["animal_momo", "animal_momo_2", "animal_momo_purr"])
        XCTAssertEqual(library.sounds(for: "iris"), ["animal_iris_1"])
        XCTAssertEqual(library.sounds(for: "nori"), [])
        XCTAssertEqual(Set(library.sounds.keys), ["momo", "iris"])
    }

    func testLongestIDWinsSoAFileNeverBelongsToTwoAnimals() {
        let ids: [CharacterID] = ["mo", "momo"]
        XCTAssertEqual(AnimalSoundLibrary.owner(of: "animal_momo_1", among: ids), "momo")
        XCTAssertEqual(AnimalSoundLibrary.owner(of: "animal_mo_1", among: ids), "mo")
        XCTAssertEqual(AnimalSoundLibrary.owner(of: "animal_mo", among: ids), "mo")
    }
}

final class CardRevealSoundPickerTests: XCTestCase {
    /// Three sounds for each of the ten animals.
    private let library = AnimalSoundLibrary(sounds: Dictionary(uniqueKeysWithValues:
        AnimalSoundLibraryTests.animals.map { id in (id, (1...3).map { "animal_\(id.rawValue)_\($0)" }) }))

    func testRepeatedFlipsAreVariedAndAlwaysMatchTheRevealedAnimal() {
        var picker = CardRevealSoundPicker()
        var generator = SeededGenerator(seed: 2026)
        var heard: [CharacterID: Set<CardRevealSound>] = [:]
        var lastAnimal: [CharacterID: String] = [:]
        var generic = 0
        let flips = 4000
        for i in 0..<flips {
            let animal = AnimalSoundLibraryTests.animals[(i * 7) % 10]
            let sound = picker.pick(for: animal, in: library, using: &generator)
            heard[animal, default: []].insert(sound)
            switch sound {
            case .generic:
                generic += 1
            case .animal(let name):
                XCTAssertTrue(library.sounds(for: animal).contains(name), "\(name) played for \(animal)")
                XCTAssertNotEqual(lastAnimal[animal], name, "same \(animal) sound twice in a row")
                lastAnimal[animal] = name
            }
        }
        for animal in AnimalSoundLibraryTests.animals {
            let expected = Set([CardRevealSound.generic] + library.sounds(for: animal).map { .animal($0) })
            XCTAssertEqual(heard[animal], expected, "\(animal) should get the generic flip and all of its sounds")
        }
        let share = Double(generic) / Double(flips)
        XCTAssertEqual(share, 0.5, accuracy: 0.05, "roughly half the flips use the generic sound")
    }

    func testAnimalWithoutSoundsOrUnknownCardUsesTheGenericFlip() {
        var picker = CardRevealSoundPicker(animalShare: 1)
        var generator = SeededGenerator(seed: 1)
        let partial = AnimalSoundLibrary(sounds: ["momo": ["animal_momo_1"]])
        for _ in 0..<200 {
            XCTAssertEqual(picker.pick(for: "iris", in: partial, using: &generator), .generic)
            XCTAssertEqual(picker.pick(for: nil, in: partial, using: &generator), .generic)
            XCTAssertEqual(picker.pick(for: "momo", in: partial, using: &generator), .animal("animal_momo_1"),
                           "a single sound may repeat")
        }
        XCTAssertEqual(CardRevealSoundPicker(animalShare: 0).animalShare, 0)
        var never = CardRevealSoundPicker(animalShare: 0)
        XCTAssertEqual(never.pick(for: "momo", in: partial, using: &generator), .generic)
    }

    func testEmptyLibraryAlwaysPlaysTheGenericFlip() {
        var picker = CardRevealSoundPicker()
        var generator = SeededGenerator(seed: 9)
        for animal in AnimalSoundLibraryTests.animals {
            XCTAssertEqual(picker.pick(for: animal, in: AnimalSoundLibrary(), using: &generator), .generic)
        }
    }
}
