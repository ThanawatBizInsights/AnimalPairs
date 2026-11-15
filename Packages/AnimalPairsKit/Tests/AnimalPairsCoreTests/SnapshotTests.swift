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

    func testQuarantineIsBounded() throws {
        let store = RoundSnapshotStore(directory: directory)
        for i in 0..<6 {
            try Data("garbage \(i)".utf8).write(to: store.fileURL)
            _ = store.load(catalog: Fixtures.catalog(), policy: Fixtures.full)
            Thread.sleep(forTimeInterval: 0.002)
        }
        XCTAssertLessThanOrEqual(store.quarantinedFiles.count, RoundSnapshotStore.maxQuarantinedFiles)
    }
}
