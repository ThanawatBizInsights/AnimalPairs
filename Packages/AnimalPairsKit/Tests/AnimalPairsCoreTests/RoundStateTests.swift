import XCTest
@testable import AnimalPairsCore

final class RoundStateTests: XCTestCase {
    func testFirstTapRevealsOneCard() throws {
        var state = try Fixtures.round()
        let id = state.tiles[0].id
        XCTAssertEqual(state.tap(id), .revealedFirst(id))
        XCTAssertEqual(state.phase, .oneRevealed(id))
        XCTAssertEqual(state.tile(id)?.face, .revealed)
        XCTAssertEqual(state.attempts, 0)
    }

    func testRepeatedTapOnSameRevealedCardIsIgnored() throws {
        var state = try Fixtures.round()
        let id = state.tiles[0].id
        _ = state.tap(id)
        XCTAssertEqual(state.tap(id), .ignored(.alreadyRevealed))
        XCTAssertEqual(state.attempts, 0)
        XCTAssertEqual(state.phase, .oneRevealed(id))
    }

    func testSecondTapIncrementsAttemptsOnceAndLocksInput() throws {
        var state = try Fixtures.round()
        let (a, b) = Fixtures.mismatchedPair(in: state)
        _ = state.tap(a)
        guard case .revealedSecond(let resolution) = state.tap(b) else { return XCTFail() }
        XCTAssertFalse(resolution.isMatch)
        XCTAssertEqual(state.attempts, 1)
        XCTAssertTrue(state.isInputLocked)
        // A third card can never be revealed during resolution.
        let third = state.tiles.first { $0.face == .covered }!.id
        XCTAssertEqual(state.tap(third), .ignored(.inputLocked))
        XCTAssertEqual(state.tiles.filter { $0.face == .revealed }.count, 2)
        XCTAssertEqual(state.attempts, 1)
    }

    func testMatchCommitsAndStaysRevealed() throws {
        var state = try Fixtures.round()
        let (a, b) = Fixtures.matchingPair(in: state)
        _ = state.tap(a)
        guard case .revealedSecond(let r) = state.tap(b) else { return XCTFail() }
        XCTAssertTrue(r.isMatch)
        XCTAssertEqual(state.finishResolution(token: r.token), .matched(state.tile(a)!.pairKey, roundCompleted: false))
        XCTAssertEqual(state.tile(a)?.face, .matched)
        XCTAssertEqual(state.tile(b)?.face, .matched)
        XCTAssertEqual(state.matchedPairs, 1)
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.tap(a), .ignored(.alreadyMatched))
    }

    func testMismatchCoversBothTogether() throws {
        var state = try Fixtures.round()
        let (a, b) = Fixtures.mismatchedPair(in: state)
        _ = state.tap(a)
        guard case .revealedSecond(let r) = state.tap(b) else { return XCTFail() }
        XCTAssertEqual(state.finishResolution(token: r.token), .coveredMismatch)
        XCTAssertEqual(state.tile(a)?.face, .covered)
        XCTAssertEqual(state.tile(b)?.face, .covered)
        XCTAssertEqual(state.phase, .ready)
    }

    func testExactImageMatchesButSameAnimalDifferentPoseDoesNot() {
        let samePose1 = Tile(id: TileID(), pairKey: "momo.play")
        let samePose2 = Tile(id: TileID(), pairKey: "momo.play")
        let otherPose1 = Tile(id: TileID(), pairKey: "momo.nap")
        let otherPose2 = Tile(id: TileID(), pairKey: "momo.nap")
        let config = GameConfiguration(mode: .exactPose, boardSize: .six)
        let extra1 = Tile(id: TileID(), pairKey: "iris.signature")
        let extra2 = Tile(id: TileID(), pairKey: "iris.signature")
        var state = RoundState(configuration: config, tiles: [samePose1, otherPose1, samePose2, otherPose2, extra1, extra2])

        _ = state.tap(samePose1.id)
        guard case .revealedSecond(let mismatch) = state.tap(otherPose1.id) else { return XCTFail() }
        XCTAssertFalse(mismatch.isMatch, "same animal, different pose must not match")
        XCTAssertEqual(state.finishResolution(token: mismatch.token), .coveredMismatch)

        _ = state.tap(samePose1.id)
        guard case .revealedSecond(let match) = state.tap(samePose2.id) else { return XCTFail() }
        XCTAssertTrue(match.isMatch, "identical artwork matches")
    }

    func testStaleTokenIsIgnored() throws {
        var state = try Fixtures.round()
        let (a, b) = Fixtures.mismatchedPair(in: state)
        _ = state.tap(a)
        guard case .revealedSecond(let r) = state.tap(b) else { return XCTFail() }
        XCTAssertEqual(state.finishResolution(token: r.token + 1), .ignoredStale)
        XCTAssertEqual(state.phase, .resolving(r))
        XCTAssertEqual(state.finishResolution(token: r.token), .coveredMismatch)
        XCTAssertEqual(state.finishResolution(token: r.token), .ignoredStale, "a duplicate callback is ignored")
    }

    func testCompletingAllPairsCompletesRound() throws {
        var state = try Fixtures.round()
        var lastOutcome: ResolutionOutcome?
        while !state.isCompleted {
            let (a, b) = Fixtures.matchingPair(in: state)
            _ = state.tap(a)
            guard case .revealedSecond(let r) = state.tap(b) else { return XCTFail() }
            lastOutcome = state.finishResolution(token: r.token, now: Date(timeIntervalSince1970: 2_000))
        }
        if case .matched(_, let completed)? = lastOutcome { XCTAssertTrue(completed) } else { XCTFail() }
        XCTAssertEqual(state.matchedPairs, 3)
        XCTAssertEqual(state.attempts, 3)
        XCTAssertEqual(state.summary?.completedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(state.tap(state.tiles[0].id), .ignored(.completed))
    }

    func testPauseCommitsPendingMatchOnce() throws {
        var state = try Fixtures.round()
        let (a, b) = Fixtures.matchingPair(in: state)
        _ = state.tap(a)
        guard case .revealedSecond(let r) = state.tap(b) else { return XCTFail() }
        XCTAssertNotNil(state.pause())
        XCTAssertTrue(state.isPaused)
        XCTAssertEqual(state.matchedPairs, 1)
        XCTAssertEqual(state.finishResolution(token: r.token), .ignoredStale, "late callback must not commit again")
        XCTAssertEqual(state.matchedPairs, 1)
        XCTAssertEqual(state.attempts, 1)
        XCTAssertEqual(state.tap(state.tiles.first { $0.face == .covered }!.id), .ignored(.paused))
        state.resume()
        XCTAssertFalse(state.isPaused)
        XCTAssertEqual(state.phase, .ready)
    }

    func testPauseCoversPendingMismatchAndKeepsSingleOpenCard() throws {
        var state = try Fixtures.round()
        let (a, b) = Fixtures.mismatchedPair(in: state)
        _ = state.tap(a)
        _ = state.tap(b)
        state.pause()
        XCTAssertEqual(state.tile(a)?.face, .covered)
        XCTAssertEqual(state.tile(b)?.face, .covered)
        state.resume()

        let c = state.tiles[0].id
        _ = state.tap(c)
        state.pause()
        XCTAssertEqual(state.phase, .oneRevealed(c), "a single revealed card is preserved")
        XCTAssertEqual(state.tile(c)?.face, .revealed)
    }

    func testHintsNeverChangeAttemptsOrMatches() throws {
        var state = try Fixtures.round(GameConfiguration(mode: .classic, boardSize: .twelve))
        var rng = SeededGenerator(seed: 3)
        guard case .pair(let x, let y)? = state.useHint(using: &rng) else { return XCTFail() }
        XCTAssertEqual(state.tile(x)?.pairKey, state.tile(y)?.pairKey)
        XCTAssertEqual(state.tile(x)?.face, .covered)
        XCTAssertEqual(state.tile(y)?.face, .covered)
        XCTAssertEqual(state.hintsUsed, 1)
        XCTAssertEqual(state.attempts, 0)
        XCTAssertEqual(state.matchedPairs, 0)

        let open = state.tiles[5]
        _ = state.tap(open.id)
        guard case .partner(let partner)? = state.useHint(using: &rng) else { return XCTFail() }
        XCTAssertEqual(state.tile(partner)?.pairKey, open.pairKey)
        XCTAssertNotEqual(partner, open.id)
        XCTAssertEqual(state.hintsUsed, 2)
        XCTAssertEqual(state.attempts, 0)
        XCTAssertEqual(state.phase, .oneRevealed(open.id), "hint does not reveal anything")
    }

    func testHintUnavailableWhileResolvingPausedOrCompleted() throws {
        var state = try Fixtures.round()
        var rng = SeededGenerator(seed: 1)
        let (a, b) = Fixtures.mismatchedPair(in: state)
        _ = state.tap(a)
        _ = state.tap(b)
        XCTAssertNil(state.useHint(using: &rng))
        state.pause()
        XCTAssertNil(state.useHint(using: &rng))
        XCTAssertEqual(state.hintsUsed, 0)
    }
}
