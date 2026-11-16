import Foundation
import XCTest
@testable import AnimalPairsCore

enum Fixtures {
    static let characterIDs: [CharacterID] = ["momo", "iris", "nori", "sprout", "mochi",
                                              "sunny", "maple", "clover", "rusty", "pebble"]
    static let poses: [PoseID] = ["signature", "play", "nap"]

    static func manifest(characters: [CharacterID] = characterIDs, poses: [PoseID] = poses) -> ArtworkManifest {
        let defs = characters.map {
            CharacterDefinition(id: $0, nameKey: "character.\($0).name", speciesKey: "character.\($0).species",
                                defaultPoseID: "signature")
        }
        var artworks: [ArtworkDefinition] = []
        for character in characters {
            for pose in poses {
                artworks.append(ArtworkDefinition(
                    assetID: AssetID(rawValue: "\(character).\(pose)"), characterID: character, poseID: pose, version: 1,
                    resourceName: "\(character)_\(pose)", accessibilityKey: "art.\(character).\(pose)",
                    tier: pose == "signature" ? .free : .premium,
                    status: pose == "signature" ? .final : .placeholder))
            }
        }
        return ArtworkManifest(manifestVersion: "test", characters: defs, artworks: artworks)
    }

    static func catalog(_ manifest: ArtworkManifest = manifest(), missing: Set<AssetID> = []) -> ContentCatalog {
        ContentCatalog(manifest: manifest, installedAssets: Set(manifest.artworks.map(\.assetID)).subtracting(missing))
    }

    static let full = ContentAccessPolicy(level: .fullGame)
    static let starter = ContentAccessPolicy(level: .starter)

    /// A deterministic round with known layout.
    static func round(_ config: GameConfiguration = GameConfiguration(mode: .classic, boardSize: .six),
                      seed: UInt64 = 42, policy: ContentAccessPolicy = full) throws -> RoundState {
        var rng = SeededGenerator(seed: seed)
        let tiles = try DeckBuilder.makeBoard(configuration: config, catalog: catalog(), policy: policy, using: &rng)
        return RoundState(configuration: config, tiles: tiles, startedAt: Date(timeIntervalSince1970: 1_000))
    }

    /// Two tile IDs sharing a pair key.
    static func matchingPair(in state: RoundState, excluding: Set<TileID> = []) -> (TileID, TileID) {
        let open = state.tiles.filter { $0.face == .covered && !excluding.contains($0.id) }
        for tile in open {
            if let partner = open.first(where: { $0.pairKey == tile.pairKey && $0.id != tile.id }) {
                return (tile.id, partner.id)
            }
        }
        fatalError("no covered pair")
    }

    /// Two covered tile IDs with different pair keys.
    static func mismatchedPair(in state: RoundState) -> (TileID, TileID) {
        let open = state.tiles.filter { $0.face == .covered }
        let first = open[0]
        let second = open.first { $0.pairKey != first.pairKey }!
        return (first.id, second.id)
    }
}

/// Deterministic scheduler: time only moves when the test says so.
@MainActor
final class ManualScheduler: RoundScheduler {
    final class Item: ScheduledWork {
        let due: Double
        let work: @MainActor () -> Void
        var cancelled = false
        var fired = false
        init(due: Double, work: @escaping @MainActor () -> Void) {
            self.due = due
            self.work = work
        }
        func cancel() { cancelled = true }
    }

    private(set) var now: Double = 0
    private(set) var items: [Item] = []

    func schedule(after seconds: Double, _ work: @escaping @MainActor () -> Void) -> ScheduledWork {
        let item = Item(due: now + seconds, work: work)
        items.append(item)
        return item
    }

    var pending: [Item] { items.filter { !$0.cancelled && !$0.fired } }

    func advance(by seconds: Double) {
        now += seconds
        while let next = items.filter({ !$0.cancelled && !$0.fired && $0.due <= now + 1e-9 }).min(by: { $0.due < $1.due }) {
            next.fired = true
            next.work()
        }
    }

    /// Simulates callbacks that run even though they were cancelled (e.g. a
    /// task that had already passed its cancellation check).
    func fireEverythingIncludingCancelled() {
        for item in items where !item.fired {
            item.fired = true
            item.work()
        }
    }
}
