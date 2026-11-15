import Foundation

/// Unique identity of one card instance on a board.
public struct TileID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue.uuidString }

    /// Deterministic ID drawn from a random generator (reproducible boards in tests).
    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> TileID {
        let a = generator.next(), b = generator.next()
        let bytes = withUnsafeBytes(of: a.bigEndian) { Array($0) } + withUnsafeBytes(of: b.bigEndian) { Array($0) }
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return TileID(uuid)
    }
}

public enum TileFace: String, Codable, Sendable {
    case covered
    case revealed
    case matched
}

/// One card. `pairKey` is immutable and names the exact artwork shown;
/// both cards of a pair carry the same key and therefore the same image.
public struct Tile: Codable, Hashable, Sendable, Identifiable {
    public let id: TileID
    public let pairKey: PairKey
    public internal(set) var face: TileFace

    public init(id: TileID, pairKey: PairKey, face: TileFace = .covered) {
        self.id = id
        self.pairKey = pairKey
        self.face = face
    }
}

public enum DeckBuilderError: Error, Equatable, Sendable {
    case configurationLocked(GameConfiguration)
    case notEnoughCharacters(needed: Int, available: Int)
    case notEnoughPoseVariety(needed: Int, available: Int)
}

public enum DeckBuilder {
    /// Builds a shuffled, covered board for `configuration`.
    public static func makeBoard<G: RandomNumberGenerator>(
        configuration: GameConfiguration,
        catalog: ContentCatalog,
        policy: ContentAccessPolicy,
        using generator: inout G
    ) throws -> [Tile] {
        guard policy.isAvailable(configuration) else { throw DeckBuilderError.configurationLocked(configuration) }
        let artworks = catalog.playableArtworks(for: policy)
        let selection = try selectArtworks(for: configuration, from: artworks, using: &generator)
        return makeTiles(for: selection.map(\.assetID), using: &generator)
    }

    /// Chooses exactly `pairCount` distinct artworks honouring the mode rules.
    public static func selectArtworks<G: RandomNumberGenerator>(
        for configuration: GameConfiguration,
        from artworks: [ArtworkDefinition],
        using generator: inout G
    ) throws -> [ArtworkDefinition] {
        // Stable grouping so a seeded generator yields reproducible boards.
        var byCharacter: [CharacterID: [ArtworkDefinition]] = [:]
        for art in artworks.sorted(by: { $0.assetID < $1.assetID }) {
            byCharacter[art.characterID, default: []].append(art)
        }
        let characters = byCharacter.keys.sorted()
        let pairs = configuration.boardSize.pairCount

        switch configuration.mode {
        case .classic:
            guard characters.count >= pairs else {
                throw DeckBuilderError.notEnoughCharacters(needed: pairs, available: characters.count)
            }
            let chosen = characters.shuffled(using: &generator).prefix(pairs)
            return chosen.map { byCharacter[$0]!.randomElement(using: &generator)! }

        case .exactPose:
            return try selectExactPose(pairs: pairs, byCharacter: byCharacter, characters: characters, using: &generator)
        }
    }

    /// Minimum number of animals that must appear in two different poses.
    public static func requiredMultiPoseAnimals(pairs: Int) -> Int {
        pairs >= 6 ? 2 : 1
    }

    private static func selectExactPose<G: RandomNumberGenerator>(
        pairs: Int,
        byCharacter: [CharacterID: [ArtworkDefinition]],
        characters: [CharacterID],
        using generator: inout G
    ) throws -> [ArtworkDefinition] {
        let multiCandidates = characters.filter { byCharacter[$0]!.count >= 2 }.shuffled(using: &generator)
        let required = requiredMultiPoseAnimals(pairs: pairs)
        guard multiCandidates.count >= required else {
            throw DeckBuilderError.notEnoughPoseVariety(needed: required, available: multiCandidates.count)
        }
        let maxMulti = min(multiCandidates.count, pairs / 2)
        guard maxMulti >= required else {
            throw DeckBuilderError.notEnoughPoseVariety(needed: required, available: maxMulti)
        }
        // Prefer a random amount of pose-heavy animals, then grow it if there are
        // not enough other animals to fill the remaining single-pose pairs.
        var multiCount = Int.random(in: required...maxMulti, using: &generator)
        while multiCount <= maxMulti {
            let multi = Array(multiCandidates.prefix(multiCount))
            let others = characters.filter { !multi.contains($0) }.shuffled(using: &generator)
            let singlesNeeded = pairs - multiCount * 2
            if singlesNeeded <= others.count {
                var result: [ArtworkDefinition] = []
                for character in multi {
                    result += byCharacter[character]!.shuffled(using: &generator).prefix(2)
                }
                for character in others.prefix(singlesNeeded) {
                    result.append(byCharacter[character]!.randomElement(using: &generator)!)
                }
                return result
            }
            multiCount += 1
        }
        throw DeckBuilderError.notEnoughCharacters(needed: pairs - maxMulti * 2, available: characters.count - maxMulti)
    }

    /// Two cards per pair key, each with a unique tile ID, then shuffled.
    public static func makeTiles<G: RandomNumberGenerator>(for pairKeys: [PairKey], using generator: inout G) -> [Tile] {
        var tiles: [Tile] = []
        tiles.reserveCapacity(pairKeys.count * 2)
        for key in pairKeys {
            tiles.append(Tile(id: .random(using: &generator), pairKey: key))
            tiles.append(Tile(id: .random(using: &generator), pairKey: key))
        }
        tiles.shuffle(using: &generator)
        return tiles
    }
}
