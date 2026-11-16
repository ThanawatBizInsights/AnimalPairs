@testable import AnimalPairsCore
import XCTest

final class AnimalClipLibraryTests: XCTestCase {
    static let animals: [CharacterID] = ["momo", "iris", "nori", "sprout", "mochi",
                                         "sunny", "maple", "clover", "rusty", "pebble"]
    static var fullLibrary: AnimalClipLibrary {
        AnimalClipLibrary(clips: animals.flatMap { a in AnimalClipVariant.allCases.map { AnimalClip(character: a, variant: $0) } })
    }

    func testFindsOnlyKnownAnimalsAndVariants() {
        let library = AnimalClipLibrary(resourceNames: [
            "momo_greeting", "momo_excited", "iris_calm", "card_flip", "pair_match", "pair_miss",
            "momo_happy", "unknown_greeting", "momo", "_greeting", "iris_calm_v2", "animal_momo",
        ], characters: Self.animals)
        XCTAssertEqual(library.clips["momo"]?.map(\.name), ["momo_excited", "momo_greeting"])
        XCTAssertEqual(library.clips["iris"]?.map(\.name), ["iris_calm"])
        XCTAssertEqual(Set(library.clips.keys), ["momo", "iris"])
    }

    func testMomentsChooseTheRightVariants() {
        let library = Self.fullLibrary
        XCTAssertEqual(Set(library.clips(for: "iris", moment: .matched).map(\.variant)), Set(AnimalClipVariant.allCases))
        XCTAssertEqual(Set(library.clips(for: "iris", moment: .homeTap).map(\.variant)), [.greeting, .curious])
        XCTAssertTrue(library.clips(for: "iris", moment: .matched).allSatisfy { $0.character == "iris" })
    }
}

final class AnimalClipPickerTests: XCTestCase {
    func testRepeatedPicksAreVariedAndAlwaysTheRequestedAnimal() {
        let library = AnimalClipLibraryTests.fullLibrary
        var picker = AnimalClipPicker()
        var generator = SeededGenerator(seed: 2026)
        var heard: [CharacterID: [AnimalClipVariant: Int]] = [:]
        var previous: [CharacterID: AnimalClip] = [:]
        for i in 0..<4000 {
            let animal = AnimalClipLibraryTests.animals[(i * 7 + i / 10) % 10]
            let clip = try! XCTUnwrap(picker.pick(for: animal, moment: .matched, in: library, using: &generator))
            XCTAssertEqual(clip.character, animal, "\(clip.name) picked for \(animal)")
            XCTAssertNotEqual(previous[animal], clip, "same clip twice in a row")
            previous[animal] = clip
            heard[animal, default: [:]][clip.variant, default: 0] += 1
        }
        for animal in AnimalClipLibraryTests.animals {
            let counts = heard[animal] ?? [:]
            XCTAssertEqual(Set(counts.keys), Set(AnimalClipVariant.allCases), "\(animal) uses all four clips")
            XCTAssertTrue(counts.values.allSatisfy { $0 > 60 }, "\(animal) spread: \(counts)")
        }
    }

    func testHomeTapsUseGreetingOrCuriousOnly() {
        let library = AnimalClipLibraryTests.fullLibrary
        var picker = AnimalClipPicker()
        var generator = SeededGenerator(seed: 5)
        var variants: Set<AnimalClipVariant> = []
        for _ in 0..<200 {
            let clip = picker.pick(for: "pebble", moment: .homeTap, in: library, using: &generator)
            XCTAssertEqual(clip?.character, "pebble")
            variants.insert(clip!.variant)
        }
        XCTAssertEqual(variants, [.greeting, .curious])
    }

    func testAnimalWithoutClipsGetsNothing() {
        var picker = AnimalClipPicker()
        var generator = SeededGenerator(seed: 1)
        let partial = AnimalClipLibrary(clips: [AnimalClip(character: "momo", variant: .calm)])
        XCTAssertNil(picker.pick(for: "iris", moment: .matched, in: partial, using: &generator))
        XCTAssertNil(picker.pick(for: "momo", moment: .homeTap, in: partial, using: &generator))
        XCTAssertEqual(picker.pick(for: "momo", moment: .matched, in: partial, using: &generator)?.name, "momo_calm")
        XCTAssertEqual(picker.pick(for: "momo", moment: .matched, in: partial, using: &generator)?.name, "momo_calm",
                       "a single clip may repeat")
    }
}

final class CooldownTests: XCTestCase {
    func testRapidRepeatsAreIgnored() {
        var cooldown = Cooldown(interval: 0.8)
        XCTAssertTrue(cooldown.accept(at: 10))
        XCTAssertFalse(cooldown.accept(at: 10.1))
        XCTAssertFalse(cooldown.accept(at: 10.79))
        XCTAssertTrue(cooldown.accept(at: 10.8))
        XCTAssertFalse(cooldown.accept(at: 11.0), "measured from the last accepted tap")
        cooldown.reset()
        XCTAssertTrue(cooldown.accept(at: 11.0))
    }
}
