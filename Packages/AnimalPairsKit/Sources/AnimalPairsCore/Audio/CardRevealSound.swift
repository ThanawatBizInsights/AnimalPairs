import Foundation

/// What plays when a card is turned face up.
public enum CardRevealSound: Equatable, Hashable, Sendable {
    /// The generic card-flip sound.
    case generic
    /// One of the revealed animal's own short sounds (a bundled resource name).
    case animal(String)
}

/// The short sounds that belong to each animal, found from bundled file names.
///
/// A file belongs to an animal when its name (without extension) is
/// `animal_<id>` or `animal_<id>_<variant>`, e.g. `animal_momo.wav`,
/// `animal_momo_2.m4a`, `animal_iris_purr.wav`. Names are matched against the
/// known character IDs (longest ID first), so a file can only ever belong to
/// one animal and a name like `animal_momox` belongs to none.
public struct AnimalSoundLibrary: Equatable, Sendable {
    public private(set) var sounds: [CharacterID: [String]]

    public init(sounds: [CharacterID: [String]] = [:]) {
        self.sounds = sounds.mapValues { Array(Set($0)).sorted() }.filter { !$0.value.isEmpty }
    }

    public init(resourceNames: some Sequence<String>, characters: some Sequence<CharacterID>) {
        let ids = Set(characters).sorted { $0.rawValue.count > $1.rawValue.count }
        var found: [CharacterID: Set<String>] = [:]
        for name in resourceNames {
            if let id = Self.owner(of: name, among: ids) {
                found[id, default: []].insert(name)
            }
        }
        self.init(sounds: found.mapValues(Array.init))
    }

    public func sounds(for character: CharacterID) -> [String] { sounds[character] ?? [] }

    /// The animal a resource name belongs to, if any.
    public static func owner(of name: String, among characters: [CharacterID]) -> CharacterID? {
        let prefix = "animal_"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        for id in characters.sorted(by: { $0.rawValue.count > $1.rawValue.count }) where !id.rawValue.isEmpty {
            if rest == id.rawValue { return id }
            let variant = rest.dropFirst(id.rawValue.count + 1)
            if rest.hasPrefix(id.rawValue + "_"), !variant.isEmpty,
               variant.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
                return id
            }
        }
        return nil
    }
}

/// Chooses the sound for each card flip.
///
/// * Each flip randomly plays either the generic flip sound or one of the
///   revealed animal's own sounds (`animalShare` of the time, when it has any).
/// * Only the revealed animal's sounds are candidates; an animal with no
///   sounds (or an unknown card) always gets the generic flip.
/// * For variety the same animal sound is not picked twice in a row for that
///   animal when it has more than one.
public struct CardRevealSoundPicker: Sendable {
    /// Chance of an animal sound when the animal has at least one.
    public var animalShare: Double
    private var lastAnimalSound: [CharacterID: String] = [:]

    public init(animalShare: Double = 0.5) {
        self.animalShare = min(1, max(0, animalShare))
    }

    public mutating func pick<G: RandomNumberGenerator>(
        for character: CharacterID?, in library: AnimalSoundLibrary, using generator: inout G
    ) -> CardRevealSound {
        guard let character else { return .generic }
        let own = library.sounds(for: character)
        guard !own.isEmpty, Double.random(in: 0..<1, using: &generator) < animalShare else { return .generic }
        var candidates = own
        if candidates.count > 1, let last = lastAnimalSound[character] {
            candidates.removeAll { $0 == last }
        }
        let choice = candidates.randomElement(using: &generator)!
        lastAnimalSound[character] = choice
        return .animal(choice)
    }

    public mutating func reset() { lastAnimalSound = [:] }
}
