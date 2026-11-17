import Foundation

/// Versioned, Codable description of an unfinished round. Always written from
/// a normalized state, so it never contains a pending resolution.
public struct RoundSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public struct TileRecord: Codable, Equatable, Sendable {
        public let id: TileID
        public let pairKey: PairKey
        public let face: TileFace
    }

    public var schemaVersion: Int
    public var savedAt: Date
    public var manifestVersion: String
    public var roundID: UUID
    public var configuration: GameConfiguration
    /// Board order is preserved exactly; restoring never reshuffles.
    public var tiles: [TileRecord]
    public var openTileID: TileID?
    public var attempts: Int
    public var hintsUsed: Int
    public var resolutionCounter: UInt64
    public var startedAt: Date

    /// Creates a snapshot from a state. The state is normalized first; a
    /// completed round has nothing to resume and yields nil.
    public init?(state: RoundState, manifestVersion: String, savedAt: Date = Date()) {
        var normalized = state
        normalized.normalize(now: savedAt)
        if normalized.isCompleted { return nil }
        schemaVersion = Self.currentSchemaVersion
        // Whole seconds: the ISO-8601 encoding does not keep fractions.
        self.savedAt = Self.wholeSeconds(savedAt)
        self.manifestVersion = manifestVersion
        roundID = normalized.roundID
        configuration = normalized.configuration
        tiles = normalized.tiles.map { TileRecord(id: $0.id, pairKey: $0.pairKey, face: $0.face) }
        if case .oneRevealed(let id) = normalized.phase { openTileID = id } else { openTileID = nil }
        attempts = normalized.attempts
        hintsUsed = normalized.hintsUsed
        resolutionCounter = normalized.resolutionCounter
        startedAt = Self.wholeSeconds(normalized.startedAt)
    }

    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// Validates the snapshot against the current content and access level and
    /// rebuilds the round. Never crashes on bad data; throws instead.
    public func restore(catalog: ContentCatalog, policy: ContentAccessPolicy) throws -> RoundState {
        let snapshot = migratingRetiredPoses(catalog: catalog, policy: policy)
        try snapshot.validate(catalog: catalog, policy: policy)
        return snapshot.rebuild()
    }

    /// Replaces pictures whose pose has been retired from the catalogue (e.g.
    /// Stretch) with another pose of the same animal, so a round saved before
    /// the change still resumes. Both cards of a pair get the same replacement,
    /// matched pairs stay matched, and the replacement is a pose that is
    /// installed, available at this access level, not already on the board
    /// and — in Exact Pose — not a look-alike of that animal's other pose.
    /// Deterministic (first suitable pose in catalogue order). Anything that
    /// cannot be migrated is left for `validate` to reject as before.
    public func migratingRetiredPoses(catalog: ContentCatalog, policy: ContentAccessPolicy) -> RoundSnapshot {
        let keys = Set(tiles.map(\.pairKey))
        let retired = keys.filter { catalog.artwork($0) == nil }.sorted()
        guard !retired.isEmpty else { return self }
        var used = keys.subtracting(retired)
        var replacement: [PairKey: PairKey] = [:]
        for key in retired {
            let parts = key.rawValue.split(separator: ".", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let animal = CharacterID(rawValue: String(parts[0]))
            let definition = catalog.manifest.character(animal)
            let others = used.compactMap(catalog.artwork).filter { $0.characterID == animal }
            let candidate = catalog.manifest.artworks(for: animal).first { art in
                !used.contains(art.assetID) && catalog.installedAssets.contains(art.assetID) && policy.isAvailable(art)
                    && (configuration.mode == .classic
                        ? others.isEmpty
                        : others.allSatisfy { definition?.canShareBoard($0.poseID, art.poseID) ?? ($0.poseID != art.poseID) })
            }
            guard let candidate else { continue }
            replacement[key] = candidate.assetID
            used.insert(candidate.assetID)
        }
        var migrated = self
        migrated.tiles = tiles.map { tile in
            TileRecord(id: tile.id, pairKey: replacement[tile.pairKey] ?? tile.pairKey, face: tile.face)
        }
        return migrated
    }

    private func rebuild() -> RoundState {
        let restoredTiles = tiles.map { Tile(id: $0.id, pairKey: $0.pairKey, face: $0.face) }
        let phase: RoundPhase = openTileID.map { .oneRevealed($0) } ?? .ready
        return RoundState(roundID: roundID, configuration: configuration, tiles: restoredTiles, phase: phase,
                          isPaused: false, attempts: attempts, hintsUsed: hintsUsed,
                          resolutionCounter: resolutionCounter, startedAt: startedAt, completedAt: nil)
    }

    public func validate(catalog: ContentCatalog, policy: ContentAccessPolicy) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SnapshotError.unsupportedSchema(schemaVersion)
        }
        guard policy.isAvailable(configuration) else { throw SnapshotError.configurationNotAvailable }
        guard tiles.count == configuration.boardSize.cardCount else {
            throw SnapshotError.wrongCardCount(expected: configuration.boardSize.cardCount, found: tiles.count)
        }
        guard Set(tiles.map(\.id)).count == tiles.count else { throw SnapshotError.duplicateTileID }

        var byKey: [PairKey: [TileRecord]] = [:]
        for tile in tiles { byKey[tile.pairKey, default: []].append(tile) }
        for (key, group) in byKey {
            guard group.count == 2 else { throw SnapshotError.invalidPairCardinality(key, group.count) }
            guard let art = catalog.artwork(key) else { throw SnapshotError.unknownArtwork(key) }
            guard catalog.installedAssets.contains(key) else { throw SnapshotError.missingArtwork(key) }
            guard policy.isAvailable(art) else { throw SnapshotError.artworkNotAvailable(key) }
            let matched = group.filter { $0.face == .matched }.count
            guard matched == 0 || matched == 2 else { throw SnapshotError.inconsistentMatch(key) }
        }

        let revealed = tiles.filter { $0.face == .revealed }
        switch (revealed.count, openTileID) {
        case (0, nil): break
        case (1, let open?) where revealed[0].id == open: break
        default: throw SnapshotError.inconsistentOpenCard
        }

        let matchedPairs = tiles.filter { $0.face == .matched }.count / 2
        guard matchedPairs < tiles.count / 2 else { throw SnapshotError.alreadyCompleted }
        guard attempts >= 0, hintsUsed >= 0, attempts >= matchedPairs else { throw SnapshotError.invalidCounters }
        guard resolutionCounter >= UInt64(attempts) else { throw SnapshotError.invalidCounters }
    }
}

public enum SnapshotError: Error, Equatable, Sendable {
    case unreadable(String)
    case unsupportedSchema(Int)
    case configurationNotAvailable
    case wrongCardCount(expected: Int, found: Int)
    case duplicateTileID
    case invalidPairCardinality(PairKey, Int)
    case unknownArtwork(PairKey)
    case missingArtwork(PairKey)
    case artworkNotAvailable(PairKey)
    case inconsistentMatch(PairKey)
    case inconsistentOpenCard
    case alreadyCompleted
    case invalidCounters
}

/// JSON encoding with an explicit schema header so future versions can migrate.
public enum SnapshotCodec {
    private struct Header: Decodable { let schemaVersion: Int }

    public static func encode(_ snapshot: RoundSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    public static func decode(_ data: Data) throws -> RoundSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw SnapshotError.unreadable("missing or invalid schemaVersion")
        }
        switch header.schemaVersion {
        case RoundSnapshot.currentSchemaVersion:
            do {
                return try decoder.decode(RoundSnapshot.self, from: data)
            } catch {
                throw SnapshotError.unreadable(String(describing: error))
            }
        // Future: `case 0: return migrateV0(data)` keeps old saves resumable.
        default:
            throw SnapshotError.unsupportedSchema(header.schemaVersion)
        }
    }
}
