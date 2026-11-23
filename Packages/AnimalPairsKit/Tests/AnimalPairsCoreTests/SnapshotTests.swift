import XCTest
@testable import AnimalPairsCore

final class SnapshotTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func midGameState() throws -> RoundState {
        var state = try Fixtures.round(GameConfiguration(mode: .exactPose, boardSize: .twelve))
        let (a, b) = Fixtures.matchingPair(in: state)
        _ = state.tap(a)
        if case .revealedSecond(let r) = state.tap(b) { _ = state.finishResolution(token: r.token) }
        let (c, d) = Fixtures.mismatchedPair(in: state)
        _ = state.tap(c)
        _ = state.tap(d) // left resolving on purpose
        var rng = SeededGenerator(seed: 1)
        _ = state.useHint(using: &rng)
        return state
    }

    func testRoundTripPreservesOrderAndNormalizes() throws {
        let state = try midGameState()
        let snapshot = try XCTUnwrap(RoundSnapshot(state: state, manifestVersion: "test"))
        let decoded = try SnapshotCodec.decode(try SnapshotCodec.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        let restored = try decoded.restore(catalog: Fixtures.catalog(), policy: Fixtures.full)
        XCTAssertEqual(restored.tiles.map(\.id), state.tiles.map(\.id), "no reshuffle")
        XCTAssertEqual(restored.tiles.map(\.pairKey), state.tiles.map(\.pairKey))
        XCTAssertEqual(restored.phase, .ready, "resolving mismatch was covered")
        XCTAssertEqual(restored.matchedPairs, 1)
        XCTAssertEqual(restored.attempts, 2)
        XCTAssertEqual(restored.hintsUsed, state.hintsUsed)
        XCTAssertEqual(restored.roundID, state.roundID)
    }

    func testPendingMatchIsCommittedOnceInSnapshot() throws {
        var state = try Fixtures.round()
        let (a, b) = Fixtures.matchingPair(in: state)
        _ = state.tap(a)
        _ = state.tap(b)
        let restored = try XCTUnwrap(RoundSnapshot(state: state, manifestVersion: "t"))
            .restore(catalog: Fixtures.catalog(), policy: Fixtures.full)
        XCTAssertEqual(restored.matchedPairs, 1)
        XCTAssertEqual(restored.attempts, 1)
    }

    func testSingleOpenCardSurvives() throws {
        var state = try Fixtures.round()
        let id = state.tiles[2].id
        _ = state.tap(id)
        let restored = try XCTUnwrap(RoundSnapshot(state: state, manifestVersion: "t"))
            .restore(catalog: Fixtures.catalog(), policy: Fixtures.full)
        XCTAssertEqual(restored.phase, .oneRevealed(id))
        XCTAssertFalse(restored.isPaused)
    }

    func testCompletedRoundProducesNoSnapshot() throws {
        var state = try Fixtures.round()
        while !state.isCompleted {
            let (a, b) = Fixtures.matchingPair(in: state)
            _ = state.tap(a)
            if case .revealedSecond(let r) = state.tap(b) { _ = state.finishResolution(token: r.token) }
        }
        XCTAssertNil(RoundSnapshot(state: state, manifestVersion: "t"))
    }

    func testCorruptFileIsRejectedAndQuarantinedNotCrashing() throws {
        let store = RoundSnapshotStore(directory: directory)
        try Data("{ not json".utf8).write(to: store.fileURL)
        guard case .rejected = store.load(catalog: Fixtures.catalog(), policy: Fixtures.full) else { return XCTFail() }
        XCTAssertFalse(store.hasSnapshot)
        XCTAssertEqual(store.quarantinedFiles.count, 1, "kept aside for diagnosis, not silently deleted")
        XCTAssertEqual(store.load(catalog: Fixtures.catalog(), policy: Fixtures.full), .none)
    }

    func testFutureSchemaIsRejected() throws {
        let store = RoundSnapshotStore(directory: directory)
        try Data(#"{"schemaVersion": 99, "anything": true}"#.utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(catalog: Fixtures.catalog(), policy: Fixtures.full), .rejected(.unsupportedSchema(99)))
    }

    func testMissingArtworkIsRejected() throws {
        let state = try Fixtures.round()
        let snapshot = try XCTUnwrap(RoundSnapshot(state: state, manifestVersion: "t"))
        let missing = state.tiles[0].pairKey
        XCTAssertThrowsError(try snapshot.restore(catalog: Fixtures.catalog(missing: [missing]), policy: Fixtures.full)) {
            XCTAssertEqual($0 as? SnapshotError, .missingArtwork(missing))
        }
    }

    func testRevokedAccessRejectsPremiumSnapshot() throws {
        let state = try Fixtures.round(GameConfiguration(mode: .exactPose, boardSize: .sixteen))
        let snapshot = try XCTUnwrap(RoundSnapshot(state: state, manifestVersion: "t"))
        XCTAssertThrowsError(try snapshot.restore(catalog: Fixtures.catalog(), policy: Fixtures.starter)) {
            XCTAssertEqual($0 as? SnapshotError, .configurationNotAvailable)
        }
    }

    func testTamperedSnapshotsAreRejected() throws {
        let state = try Fixtures.round(GameConfiguration(mode: .classic, boardSize: .twelve))
        let base = try XCTUnwrap(RoundSnapshot(state: state, manifestVersion: "t"))
        let catalog = Fixtures.catalog()

        var tooFew = base
        tooFew.tiles.removeLast()
        XCTAssertThrowsError(try tooFew.restore(catalog: catalog, policy: Fixtures.full))

        var tripled = base
        tripled.tiles[1] = .init(id: tripled.tiles[1].id, pairKey: tripled.tiles[0].pairKey, face: .covered)
        XCTAssertThrowsError(try tripled.restore(catalog: catalog, policy: Fixtures.full))

        var halfMatched = base
        halfMatched.tiles[0] = .init(id: base.tiles[0].id, pairKey: base.tiles[0].pairKey, face: .matched)
        halfMatched.attempts = 1
        halfMatched.resolutionCounter = 1
        XCTAssertThrowsError(try halfMatched.restore(catalog: catalog, policy: Fixtures.full)) {
            XCTAssertEqual($0 as? SnapshotError, .inconsistentMatch(base.tiles[0].pairKey))
        }

        var twoOpen = base
        twoOpen.tiles[0] = .init(id: base.tiles[0].id, pairKey: base.tiles[0].pairKey, face: .revealed)
        twoOpen.tiles[1] = .init(id: base.tiles[1].id, pairKey: base.tiles[1].pairKey, face: .revealed)
        twoOpen.openTileID = base.tiles[0].id
        XCTAssertThrowsError(try twoOpen.restore(catalog: catalog, policy: Fixtures.full)) {
            XCTAssertEqual($0 as? SnapshotError, .inconsistentOpenCard)
        }

        var duplicateID = base
        duplicateID.tiles[1] = .init(id: base.tiles[0].id, pairKey: base.tiles[1].pairKey, face: .covered)
        XCTAssertThrowsError(try duplicateID.restore(catalog: catalog, policy: Fixtures.full))

        var unknown = base
        let key = base.tiles[0].pairKey
        unknown.tiles = base.tiles.map { $0.pairKey == key ? .init(id: $0.id, pairKey: "ghost.pose", face: $0.face) : $0 }
        XCTAssertThrowsError(try unknown.restore(catalog: catalog, policy: Fixtures.full)) {
            XCTAssertEqual($0 as? SnapshotError, .unknownArtwork("ghost.pose"))
        }

        var negative = base
        negative.attempts = -1
        XCTAssertThrowsError(try negative.restore(catalog: catalog, policy: Fixtures.full))
    }

    func testStoreSaveLoadClear() throws {
        let store = RoundSnapshotStore(directory: directory.appendingPathComponent("nested"))
        let state = try midGameState()
        try store.save(state: state, manifestVersion: "t")
        XCTAssertTrue(store.hasSnapshot)
        guard case .restored(let restored) = store.load(catalog: Fixtures.catalog(), policy: Fixtures.full) else {
            return XCTFail()
        }
        XCTAssertEqual(restored.roundID, state.roundID)
        try store.clear()
        XCTAssertFalse(store.hasSnapshot)
        XCTAssertEqual(store.load(catalog: Fixtures.catalog(), policy: Fixtures.full), .none)
    }

    // MARK: Paid rounds while access is unknown or absent

    /// A valid Full Game Unlock round, loaded before StoreKit has confirmed
    /// the purchase, stays on disk and becomes resumable once it has.
    func testPaidSaveSurvivesLockedLoadAndResumesWhenUnlocked() throws {
        let store = RoundSnapshotStore(directory: directory)
        for config in [GameConfiguration(mode: .classic, boardSize: .twenty),
                       GameConfiguration(mode: .exactPose, boardSize: .six)] {
            let state = try Fixtures.round(config)
            try store.save(state: state, manifestVersion: "t")
            guard case .locked(let reason) = store.load(catalog: Fixtures.catalog(), policy: Fixtures.starter) else {
                return XCTFail("expected .locked for \(config)")
            }
            XCTAssertTrue(reason.isAccessRestriction)
            XCTAssertTrue(store.hasSnapshot, "the save is kept on disk")
            XCTAssertTrue(store.quarantinedFiles.isEmpty, "not quarantined")
            // Loading again while still locked changes nothing.
            guard case .locked = store.load(catalog: Fixtures.catalog(), policy: Fixtures.starter) else { return XCTFail() }
            // Entitlement arrives.
            guard case .restored(let restored) = store.load(catalog: Fixtures.catalog(), policy: Fixtures.full) else {
                return XCTFail("expected .restored for \(config)")
            }
            XCTAssertEqual(restored.roundID, state.roundID)
            XCTAssertEqual(restored.tiles.map(\.id), state.tiles.map(\.id), "same card order")
        }
    }

    /// A broken file is still quarantined even when the access level is
    /// also too low, so a locked result never hides corruption.
    func testMalformedPaidSaveIsStillQuarantinedWhileLocked() throws {
        let store = RoundSnapshotStore(directory: directory)
        let state = try Fixtures.round(GameConfiguration(mode: .exactPose, boardSize: .sixteen))
        var snapshot = try XCTUnwrap(RoundSnapshot(state: state, manifestVersion: "t"))
        snapshot.tiles.removeLast()
        try store.save(snapshot)
        guard case .rejected(let error) = store.load(catalog: Fixtures.catalog(), policy: Fixtures.starter) else {
            return XCTFail()
        }
        XCTAssertFalse(error.isAccessRestriction)
        XCTAssertFalse(store.hasSnapshot)
        XCTAssertEqual(store.quarantinedFiles.count, 1)
    }

    func testQuarantineIsBounded() throws {
        let store = RoundSnapshotStore(directory: directory)
        for i in 0..<6 {
            try Data("garbage \(i)".utf8).write(to: store.fileURL)
            _ = store.load(catalog: Fixtures.catalog(), policy: Fixtures.full)
            Thread.sleep(forTimeInterval: 0.002)
        }
        XCTAssertLessThanOrEqual(store.quarantinedFiles.count, RoundSnapshotStore.maxQuarantinedFiles)
    }

    // MARK: Retired poses (e.g. Stretch)

    /// A board dealt while Stretch existed, saved, then restored with a
    /// catalogue that no longer has it.
    private func savedRoundWithStretch(_ mode: GameMode, seed: UInt64) throws -> (RoundSnapshot, Set<PairKey>) {
        let old = Fixtures.manifest(poses: ["signature", "play", "nap", "stretch"])
        var rng = SeededGenerator(seed: seed)
        var tiles: [Tile] = []
        repeat {   // deal until a Stretch picture is on the board
            tiles = try DeckBuilder.makeBoard(configuration: GameConfiguration(mode: mode, boardSize: .twelve),
                                              catalog: Fixtures.catalog(old), policy: Fixtures.full, using: &rng)
        } while !tiles.contains { $0.pairKey.rawValue.hasSuffix(".stretch") }
        var state = RoundState(configuration: GameConfiguration(mode: mode, boardSize: .twelve), tiles: tiles)
        // Match the Stretch pair, so a matched retired pair must stay matched.
        // (A board may hold Stretch pictures of two animals: match one pair.)
        let key = try XCTUnwrap(state.tiles.first { $0.pairKey.rawValue.hasSuffix(".stretch") }?.pairKey)
        let pair = state.tiles.filter { $0.pairKey == key }
        _ = state.tap(pair[0].id)
        if case .revealedSecond(let r) = state.tap(pair[1].id) { _ = state.finishResolution(token: r.token) }
        XCTAssertEqual(state.matchedPairs, 1)
        let snapshot = try XCTUnwrap(RoundSnapshot(state: state, manifestVersion: "old"))
        return (snapshot, [key])
    }

    func testRoundsSavedWithARetiredPoseStillResume() throws {
        let current = Fixtures.catalog(Fixtures.manifest(poses: ["signature", "play", "nap", "football"]))
        for mode in GameMode.allCases {
            for seed in 1...25 as ClosedRange<UInt64> {
                let (snapshot, retired) = try savedRoundWithStretch(mode, seed: seed)
                let restored = try snapshot.restore(catalog: current, policy: Fixtures.full)
                XCTAssertFalse(restored.tiles.contains { $0.pairKey.rawValue.hasSuffix(".stretch") }, "no Stretch left")
                XCTAssertEqual(restored.tiles.map(\.id), snapshot.tiles.map(\.id), "same layout")
                XCTAssertEqual(restored.matchedPairs, 1, "the matched pair stays matched")
                let byKey = Dictionary(grouping: restored.tiles, by: \.pairKey)
                XCTAssertTrue(byKey.values.allSatisfy { $0.count == 2 }, "both cards of a pair share one picture")
                // Same animal as before.
                let oldAnimal = retired.first!.rawValue.split(separator: ".")[0]
                let migrated = restored.tiles.first { $0.face == .matched }!.pairKey
                XCTAssertEqual(migrated.rawValue.split(separator: ".")[0], oldAnimal)
                XCTAssertNotNil(current.artwork(migrated))
            }
        }
    }

    func testRoundsWithoutRetiredPosesAreUnchanged() throws {
        let state = try midGameState()
        let snapshot = try XCTUnwrap(RoundSnapshot(state: state, manifestVersion: "test"))
        XCTAssertEqual(snapshot.migratingRetiredPoses(catalog: Fixtures.catalog(), policy: Fixtures.full), snapshot)
    }
}
