import Foundation

/// What the player may access. Purchases map onto this; the engine never
/// talks to StoreKit directly.
public enum AccessLevel: String, Codable, Sendable {
    /// Free: Classic with 6 cards.
    case starter
    /// "Animal Pairs Plus" (an active subscription).
    case fullGame
}

/// Free vs Animal Pairs Plus.
///
/// Free: Classic mode, 6-card board, every character's default picture.
/// Plus: adds the 12-, 16- and 20-card boards, Exact Pose and every pose.
public struct ContentAccessPolicy: Sendable, Equatable {
    public var level: AccessLevel

    public init(level: AccessLevel) { self.level = level }

    public static let starterModes: Set<GameMode> = [.classic]
    public static let starterBoards: Set<BoardSize> = [.six]

    public func isAvailable(_ mode: GameMode) -> Bool {
        level == .fullGame || Self.starterModes.contains(mode)
    }

    public func isAvailable(_ board: BoardSize) -> Bool {
        level == .fullGame || Self.starterBoards.contains(board)
    }

    public func isAvailable(_ configuration: GameConfiguration) -> Bool {
        isAvailable(configuration.mode) && isAvailable(configuration.boardSize)
    }

    public func isAvailable(_ artwork: ArtworkDefinition) -> Bool {
        level == .fullGame || artwork.tier == .free
    }
}

/// The playable content: manifest entries that are both entitled and whose
/// image resource is actually present on this device.
public struct ContentCatalog: Sendable, Equatable {
    public let manifest: ArtworkManifest
    public let installedAssets: Set<AssetID>

    public init(manifest: ArtworkManifest, installedAssets: Set<AssetID>) {
        self.manifest = manifest
        self.installedAssets = installedAssets
    }

    /// Manifest artworks whose resources are missing on this device.
    public var missingArtworks: [ArtworkDefinition] {
        manifest.artworks.filter { !installedAssets.contains($0.assetID) }
    }

    public func playableArtworks(for policy: ContentAccessPolicy) -> [ArtworkDefinition] {
        manifest.artworks.filter { installedAssets.contains($0.assetID) && policy.isAvailable($0) }
    }

    /// Characters that have at least one playable artwork under `policy`.
    public func playableCharacters(for policy: ContentAccessPolicy) -> [CharacterDefinition] {
        let ids = Set(playableArtworks(for: policy).map(\.characterID))
        return manifest.characters.filter { ids.contains($0.id) }
    }

    public func artwork(_ id: AssetID) -> ArtworkDefinition? { manifest.artwork(id) }
}
