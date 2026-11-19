import Foundation

/// What the player may access. Purchases map onto this; the engine never
/// talks to StoreKit directly.
public enum AccessLevel: String, Codable, Sendable {
    /// Free: Classic with 6 or 12 cards, unlimited play.
    case starter
    /// "Full Game Unlock" (a one-time, non-consumable purchase) is owned.
    case fullGame
}

/// Something a purchase can unlock. Each case is listed here on purpose: a
/// future theme or pack gets its own case and is only granted by a product
/// that explicitly lists it (see `FullGameUnlock.features`).
public enum PremiumFeature: String, CaseIterable, Codable, Sendable {
    /// Exact Pose mode, at every board size.
    case exactPoseMode
    /// The 16-card board (Classic; Exact Pose needs `exactPoseMode` too).
    case sixteenCardBoard
    /// The 20-card board.
    case twentyCardBoard
    /// The 70 extra pose pictures (every animal in seven more poses).
    case extraPoses
}

/// The one-time "Full Game Unlock" (non-consumable; bought once, never
/// expires). This set is the whole definition of what it includes. It does
/// NOT automatically include future themes: adding a case to
/// `PremiumFeature` leaves it locked until it is added here, deliberately.
public enum FullGameUnlock {
    public static let features: Set<PremiumFeature> = [
        .exactPoseMode, .sixteenCardBoard, .twentyCardBoard, .extraPoses,
    ]
}

/// Free vs Full Game Unlock.
///
/// Free: Classic mode with 6 or 12 cards, every character's default picture,
/// unlimited play.
/// Full Game Unlock: adds Classic 16 and 20, Exact Pose at every board size
/// and every pose picture (`FullGameUnlock.features`).
public struct ContentAccessPolicy: Sendable, Equatable {
    public var level: AccessLevel

    public init(level: AccessLevel) { self.level = level }

    public static let starterModes: Set<GameMode> = [.classic]
    public static let starterBoards: Set<BoardSize> = [.six, .twelve]

    /// Features this access level grants.
    public var grantedFeatures: Set<PremiumFeature> {
        level == .fullGame ? FullGameUnlock.features : []
    }

    /// The feature a mode needs (nil: free).
    public static func requiredFeature(for mode: GameMode) -> PremiumFeature? {
        switch mode {
        case .classic: nil
        case .exactPose: .exactPoseMode
        }
    }

    /// The feature a board size needs (nil: free).
    public static func requiredFeature(for board: BoardSize) -> PremiumFeature? {
        switch board {
        case .six, .twelve: nil
        case .sixteen: .sixteenCardBoard
        case .twenty: .twentyCardBoard
        }
    }

    public func isAvailable(_ mode: GameMode) -> Bool {
        Self.requiredFeature(for: mode).map(grantedFeatures.contains) ?? true
    }

    public func isAvailable(_ board: BoardSize) -> Bool {
        Self.requiredFeature(for: board).map(grantedFeatures.contains) ?? true
    }

    /// A round is available only when both its mode and its board are:
    /// Exact Pose is locked at every size, including 6 and 12.
    public func isAvailable(_ configuration: GameConfiguration) -> Bool {
        isAvailable(configuration.mode) && isAvailable(configuration.boardSize)
    }

    public func isAvailable(_ artwork: ArtworkDefinition) -> Bool {
        artwork.tier == .free || grantedFeatures.contains(.extraPoses)
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
