import Foundation

/// The four moods every animal has a clip for.
public enum AnimalClipVariant: String, CaseIterable, Codable, Sendable {
    case greeting, curious, excited, calm
}

/// One bundled animal clip, e.g. `iris_greeting`.
public struct AnimalClip: Hashable, Comparable, Sendable {
    public let name: String
    public let character: CharacterID
    public let variant: AnimalClipVariant

    public init(character: CharacterID, variant: AnimalClipVariant) {
        self.character = character
        self.variant = variant
        name = "\(character.rawValue)_\(variant.rawValue)"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.name < rhs.name }
}

/// When an animal clip may play, and which of the animal's clips fit.
public enum AnimalClipMoment: Sendable {
    /// A pair of this animal was just confirmed: any of its four clips (played
    /// short). This is the only moment animal clips are heard.
    case matched

    public var variants: Set<AnimalClipVariant> {
        switch self {
        case .matched: Set(AnimalClipVariant.allCases)
        }
    }
}

/// The clips that belong to each animal, found from bundled file names
/// `<character>_<variant>` (e.g. `momo_excited.m4a`). A file belongs to at most
/// one animal, and only the known variants count, so other sounds such as
/// `card_flip` or `pair_match` are never mistaken for animal clips.
public struct AnimalClipLibrary: Equatable, Sendable {
    public private(set) var clips: [CharacterID: [AnimalClip]]

    public init(clips: some Sequence<AnimalClip> = []) {
        var grouped: [CharacterID: Set<AnimalClip>] = [:]
        for clip in clips { grouped[clip.character, default: []].insert(clip) }
        self.clips = grouped.mapValues { $0.sorted() }
    }

    public init(resourceNames: some Sequence<String>, characters: some Sequence<CharacterID>) {
        let known = Set(characters)
        self.init(clips: resourceNames.compactMap { Self.clip(named: $0, among: known) })
    }

    /// The clip a resource name stands for, if it is `<known character>_<variant>`.
    public static func clip(named name: String, among characters: Set<CharacterID>) -> AnimalClip? {
        guard let split = name.lastIndex(of: "_"),
              let variant = AnimalClipVariant(rawValue: String(name[name.index(after: split)...])) else { return nil }
        let character = CharacterID(rawValue: String(name[..<split]))
        guard characters.contains(character) else { return nil }
        return AnimalClip(character: character, variant: variant)
    }

    public func clips(for character: CharacterID, moment: AnimalClipMoment) -> [AnimalClip] {
        (clips[character] ?? []).filter { moment.variants.contains($0.variant) }
    }

    public var isEmpty: Bool { clips.isEmpty }
}

/// Picks one clip at random from the animal's candidates, never the same clip
/// twice in a row for that animal when it has another to offer.
public struct AnimalClipPicker: Sendable {
    private var last: [CharacterID: AnimalClip] = [:]

    public init() {}

    public mutating func pick<G: RandomNumberGenerator>(
        for character: CharacterID, moment: AnimalClipMoment, in library: AnimalClipLibrary, using generator: inout G
    ) -> AnimalClip? {
        var candidates = library.clips(for: character, moment: moment)
        if candidates.count > 1, let previous = last[character] {
            candidates.removeAll { $0 == previous }
        }
        guard let clip = candidates.randomElement(using: &generator) else { return nil }
        last[character] = clip
        return clip
    }

    public mutating func reset() { last = [:] }
}
