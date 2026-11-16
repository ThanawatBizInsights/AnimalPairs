import Foundation

/// Stable identifier of an animal character, e.g. `momo`.
public struct CharacterID: RawRepresentable, Hashable, Codable, Sendable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// Identifier of a pose within a character, e.g. `signature`, `play`, `nap`.
public struct PoseID: RawRepresentable, Hashable, Codable, Sendable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// Identifier of one saved illustration. It is also the immutable pair key:
/// two cards match if and only if they reference the same `AssetID`.
public struct AssetID: RawRepresentable, Hashable, Codable, Sendable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// The pair key of a card is the exact artwork it shows.
public typealias PairKey = AssetID

public enum ContentTier: String, Codable, Sendable, CaseIterable {
    /// Included in the free starter.
    case free
    /// Requires the one-time full-game unlock.
    case premium
}

public enum ArtworkStatus: String, Codable, Sendable {
    /// Approved production illustration.
    case final
    /// Development placeholder. Never release-ready.
    case placeholder
}

public struct CharacterDefinition: Codable, Hashable, Sendable {
    public let id: CharacterID
    public let nameKey: String
    public let speciesKey: String
    public let defaultPoseID: PoseID
    /// Poses of this character that look alike at card size (e.g. sitting and
    /// sitting while waving). Exact Pose never deals two poses of one group on
    /// the same board, so every pose difference stays fair for young children.
    /// Each pose still only matches itself. Optional in the manifest.
    public let lookalikePoseGroups: [[PoseID]]?

    public init(id: CharacterID, nameKey: String, speciesKey: String, defaultPoseID: PoseID,
                lookalikePoseGroups: [[PoseID]]? = nil) {
        self.id = id
        self.nameKey = nameKey
        self.speciesKey = speciesKey
        self.defaultPoseID = defaultPoseID
        self.lookalikePoseGroups = lookalikePoseGroups
    }

    /// Poses in the same look-alike group as `pose` (always including itself).
    public func lookalikes(of pose: PoseID) -> Set<PoseID> {
        let group = lookalikePoseGroups?.first { $0.contains(pose) } ?? []
        return Set(group).union([pose])
    }

    /// True when the two poses may share an Exact Pose board.
    public func canShareBoard(_ a: PoseID, _ b: PoseID) -> Bool {
        a != b && !lookalikes(of: a).contains(b)
    }
}

public struct ArtworkDefinition: Codable, Hashable, Sendable, Identifiable {
    public let assetID: AssetID
    public let characterID: CharacterID
    public let poseID: PoseID
    public let version: Int
    /// Name of the bundled image resource (asset catalog image set).
    public let resourceName: String
    /// String Catalog key for the VoiceOver description (animal + pose).
    public let accessibilityKey: String
    public let tier: ContentTier
    public let status: ArtworkStatus

    public var id: AssetID { assetID }

    public init(assetID: AssetID, characterID: CharacterID, poseID: PoseID, version: Int, resourceName: String,
                accessibilityKey: String, tier: ContentTier, status: ArtworkStatus) {
        self.assetID = assetID
        self.characterID = characterID
        self.poseID = poseID
        self.version = version
        self.resourceName = resourceName
        self.accessibilityKey = accessibilityKey
        self.tier = tier
        self.status = status
    }
}

public enum ManifestError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case duplicateCharacter(CharacterID)
    case duplicateAsset(AssetID)
    case duplicatePose(CharacterID, PoseID)
    case duplicateResource(String)
    case unknownCharacter(AssetID, CharacterID)
    case missingDefaultPose(CharacterID)
    case defaultPoseNotFree(CharacterID)
    case invalidVersion(AssetID)
    case emptyField(String)
    /// A look-alike group names a pose the character has no artwork for, or a
    /// pose appears in two groups.
    case invalidLookalikeGroup(CharacterID, PoseID)
}

/// Versioned description of every bundled (or remotely delivered) illustration.
public struct ArtworkManifest: Codable, Hashable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let manifestVersion: String
    public let characters: [CharacterDefinition]
    public let artworks: [ArtworkDefinition]

    public init(schemaVersion: Int = ArtworkManifest.supportedSchemaVersion, manifestVersion: String,
                characters: [CharacterDefinition], artworks: [ArtworkDefinition]) {
        self.schemaVersion = schemaVersion
        self.manifestVersion = manifestVersion
        self.characters = characters
        self.artworks = artworks
    }

    public static func decode(_ data: Data) throws -> ArtworkManifest {
        let manifest = try JSONDecoder().decode(ArtworkManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    /// Structural validation. Throws the first problem found.
    public func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else { throw ManifestError.unsupportedSchema(schemaVersion) }
        var characterIDs = Set<CharacterID>()
        for character in characters {
            if character.id.rawValue.isEmpty { throw ManifestError.emptyField("character.id") }
            guard characterIDs.insert(character.id).inserted else { throw ManifestError.duplicateCharacter(character.id) }
        }
        var assets = Set<AssetID>()
        var poses = Set<String>()
        var resources = Set<String>()
        for art in artworks {
            if art.assetID.rawValue.isEmpty { throw ManifestError.emptyField("assetID") }
            if art.resourceName.isEmpty { throw ManifestError.emptyField("resourceName(\(art.assetID))") }
            if art.accessibilityKey.isEmpty { throw ManifestError.emptyField("accessibilityKey(\(art.assetID))") }
            guard art.version >= 1 else { throw ManifestError.invalidVersion(art.assetID) }
            guard characterIDs.contains(art.characterID) else { throw ManifestError.unknownCharacter(art.assetID, art.characterID) }
            guard assets.insert(art.assetID).inserted else { throw ManifestError.duplicateAsset(art.assetID) }
            guard poses.insert("\(art.characterID.rawValue)/\(art.poseID.rawValue)").inserted else {
                throw ManifestError.duplicatePose(art.characterID, art.poseID)
            }
            guard resources.insert(art.resourceName).inserted else { throw ManifestError.duplicateResource(art.resourceName) }
        }
        for character in characters {
            guard let defaultArt = artworks.first(where: { $0.characterID == character.id && $0.poseID == character.defaultPoseID }) else {
                throw ManifestError.missingDefaultPose(character.id)
            }
            guard defaultArt.tier == .free else { throw ManifestError.defaultPoseNotFree(character.id) }
            var grouped = Set<PoseID>()
            for pose in (character.lookalikePoseGroups ?? []).joined() {
                guard grouped.insert(pose).inserted,
                      poses.contains("\(character.id.rawValue)/\(pose.rawValue)") else {
                    throw ManifestError.invalidLookalikeGroup(character.id, pose)
                }
            }
        }
    }

    public func artwork(_ id: AssetID) -> ArtworkDefinition? { artworks.first { $0.assetID == id } }
    public func character(_ id: CharacterID) -> CharacterDefinition? { characters.first { $0.id == id } }

    /// The central animal-and-pose catalogue: every pose of a character, in
    /// manifest order.
    public func artworks(for character: CharacterID) -> [ArtworkDefinition] {
        artworks.filter { $0.characterID == character }
    }

    public var placeholderArtworks: [ArtworkDefinition] { artworks.filter { $0.status == .placeholder } }
    public var isReleaseReady: Bool { placeholderArtworks.isEmpty }
}
