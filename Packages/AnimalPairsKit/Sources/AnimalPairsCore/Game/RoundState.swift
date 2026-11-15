import Foundation

/// A pending comparison of two revealed cards.
public struct Resolution: Codable, Hashable, Sendable {
    public let first: TileID
    public let second: TileID
    public let isMatch: Bool
    /// Monotonic per round; a delayed callback must present the same token.
    public let token: UInt64
}

/// Serial state machine: ready → oneRevealed → resolving → ready | completed.
/// Pausing is orthogonal (`RoundState.isPaused`) and always happens from a
/// settled phase, because `pause()` first applies any pending resolution.
public enum RoundPhase: Hashable, Sendable {
    case ready
    case oneRevealed(TileID)
    case resolving(Resolution)
    case completed
}

public enum TapIgnoredReason: Equatable, Sendable {
    case paused
    case completed
    case inputLocked
    case unknownTile
    case alreadyMatched
    case alreadyRevealed
}

public enum TapOutcome: Equatable, Sendable {
    case ignored(TapIgnoredReason)
    case revealedFirst(TileID)
    /// Second card revealed; the caller must schedule `finishResolution(token:)`.
    case revealedSecond(Resolution)
}

public enum ResolutionOutcome: Equatable, Sendable {
    /// Token did not match the pending resolution (stale or duplicate callback).
    case ignoredStale
    case matched(PairKey, roundCompleted: Bool)
    case coveredMismatch
}

public enum HintTarget: Equatable, Sendable {
    /// No card open: two covered cards that match each other.
    case pair(TileID, TileID)
    /// One card open: its covered partner.
    case partner(TileID)
}

/// Facts about a finished round, used for results and local history.
public struct RoundSummary: Codable, Hashable, Sendable {
    public let roundID: UUID
    public let configuration: GameConfiguration
    public let attempts: Int
    public let hintsUsed: Int
    public let pairCount: Int
    public let startedAt: Date
    public let completedAt: Date

    public init(roundID: UUID, configuration: GameConfiguration, attempts: Int, hintsUsed: Int,
                pairCount: Int, startedAt: Date, completedAt: Date) {
        self.roundID = roundID
        self.configuration = configuration
        self.attempts = attempts
        self.hintsUsed = hintsUsed
        self.pairCount = pairCount
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// The complete, pure game state for one round. All rules live here; there is
/// no timing, UI or persistence in this type.
public struct RoundState: Hashable, Sendable {
    public let roundID: UUID
    public let configuration: GameConfiguration
    public private(set) var tiles: [Tile]
    public private(set) var phase: RoundPhase
    public private(set) var isPaused: Bool
    /// Incremented once per second card revealed.
    public private(set) var attempts: Int
    /// Recorded separately; never affects attempts or matches.
    public private(set) var hintsUsed: Int
    public private(set) var resolutionCounter: UInt64
    public let startedAt: Date
    public private(set) var completedAt: Date?

    public init(roundID: UUID = UUID(), configuration: GameConfiguration, tiles: [Tile], startedAt: Date = Date()) {
        self.roundID = roundID
        self.configuration = configuration
        self.tiles = tiles.map { Tile(id: $0.id, pairKey: $0.pairKey, face: .covered) }
        self.phase = .ready
        self.isPaused = false
        self.attempts = 0
        self.hintsUsed = 0
        self.resolutionCounter = 0
        self.startedAt = startedAt
        self.completedAt = nil
    }

    /// Restores a validated, normalized state (used by snapshots).
    init(roundID: UUID, configuration: GameConfiguration, tiles: [Tile], phase: RoundPhase, isPaused: Bool,
         attempts: Int, hintsUsed: Int, resolutionCounter: UInt64, startedAt: Date, completedAt: Date?) {
        self.roundID = roundID
        self.configuration = configuration
        self.tiles = tiles
        self.phase = phase
        self.isPaused = isPaused
        self.attempts = attempts
        self.hintsUsed = hintsUsed
        self.resolutionCounter = resolutionCounter
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    // MARK: Derived

    public var totalPairs: Int { tiles.count / 2 }
    public var matchedPairs: Int { tiles.filter { $0.face == .matched }.count / 2 }
    public var isCompleted: Bool { phase == .completed }
    public var isInputLocked: Bool {
        if isPaused { return true }
        switch phase {
        case .resolving, .completed: return true
        case .ready, .oneRevealed: return false
        }
    }

    public var pendingResolution: Resolution? {
        if case .resolving(let resolution) = phase { return resolution }
        return nil
    }

    public func tile(_ id: TileID) -> Tile? { tiles.first { $0.id == id } }

    public var summary: RoundSummary? {
        guard let completedAt else { return nil }
        return RoundSummary(roundID: roundID, configuration: configuration, attempts: attempts, hintsUsed: hintsUsed,
                            pairCount: totalPairs, startedAt: startedAt, completedAt: completedAt)
    }

    private func index(of id: TileID) -> Int? { tiles.firstIndex { $0.id == id } }

    // MARK: Input

    public mutating func tap(_ id: TileID) -> TapOutcome {
        if isPaused { return .ignored(.paused) }
        guard let index = index(of: id) else { return .ignored(.unknownTile) }
        switch phase {
        case .completed:
            return .ignored(.completed)
        case .resolving:
            return .ignored(.inputLocked)
        case .ready:
            switch tiles[index].face {
            case .matched: return .ignored(.alreadyMatched)
            case .revealed: return .ignored(.alreadyRevealed)
            case .covered:
                tiles[index].face = .revealed
                phase = .oneRevealed(id)
                return .revealedFirst(id)
            }
        case .oneRevealed(let firstID):
            switch tiles[index].face {
            case .matched: return .ignored(.alreadyMatched)
            case .revealed: return .ignored(.alreadyRevealed)
            case .covered:
                guard let firstIndex = self.index(of: firstID) else { return .ignored(.unknownTile) }
                tiles[index].face = .revealed
                attempts += 1
                resolutionCounter += 1
                let resolution = Resolution(first: firstID, second: id,
                                            isMatch: tiles[firstIndex].pairKey == tiles[index].pairKey,
                                            token: resolutionCounter)
                phase = .resolving(resolution)
                return .revealedSecond(resolution)
            }
        }
    }

    /// Completes the pending comparison. Ignored unless `token` is current.
    public mutating func finishResolution(token: UInt64, now: Date = Date()) -> ResolutionOutcome {
        guard case .resolving(let resolution) = phase, resolution.token == token else { return .ignoredStale }
        return commit(resolution, now: now)
    }

    private mutating func commit(_ resolution: Resolution, now: Date) -> ResolutionOutcome {
        guard let a = index(of: resolution.first), let b = index(of: resolution.second) else {
            phase = .ready
            return .ignoredStale
        }
        if resolution.isMatch {
            tiles[a].face = .matched
            tiles[b].face = .matched
            let done = tiles.allSatisfy { $0.face == .matched }
            if done {
                phase = .completed
                completedAt = now
            } else {
                phase = .ready
            }
            return .matched(tiles[a].pairKey, roundCompleted: done)
        } else {
            tiles[a].face = .covered
            tiles[b].face = .covered
            phase = .ready
            return .coveredMismatch
        }
    }

    // MARK: Pause & normalization

    /// Applies a pending resolution immediately: commits a matching pair once,
    /// covers a mismatched pair. A single revealed card is preserved.
    @discardableResult
    public mutating func normalize(now: Date = Date()) -> ResolutionOutcome? {
        guard case .resolving(let resolution) = phase else { return nil }
        return commit(resolution, now: now)
    }

    @discardableResult
    public mutating func pause(now: Date = Date()) -> ResolutionOutcome? {
        let outcome = normalize(now: now)
        if phase != .completed { isPaused = true }
        return outcome
    }

    public mutating func resume() {
        isPaused = false
    }

    // MARK: Hints

    /// Returns cards to outline, or nil when a hint is not meaningful right now.
    /// Hints are counted separately and never change attempts or matches.
    public mutating func useHint<G: RandomNumberGenerator>(using generator: inout G) -> HintTarget? {
        guard !isPaused else { return nil }
        switch phase {
        case .resolving, .completed:
            return nil
        case .oneRevealed(let openID):
            guard let open = tile(openID),
                  let partner = tiles.first(where: { $0.pairKey == open.pairKey && $0.id != openID && $0.face == .covered })
            else { return nil }
            hintsUsed += 1
            return .partner(partner.id)
        case .ready:
            var covered: [PairKey: [TileID]] = [:]
            for tile in tiles where tile.face == .covered { covered[tile.pairKey, default: []].append(tile.id) }
            let candidates = covered.filter { $0.value.count == 2 }.keys.sorted()
            guard let key = candidates.randomElement(using: &generator), let ids = covered[key] else { return nil }
            hintsUsed += 1
            return .pair(ids[0], ids[1])
        }
    }
}
