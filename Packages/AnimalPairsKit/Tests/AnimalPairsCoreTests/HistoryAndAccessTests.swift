import XCTest
@testable import AnimalPairsCore

final class CompletionHistoryTests: XCTestCase {
    private func summary(_ i: Int, id: UUID = UUID(), board: BoardSize = .six) -> RoundSummary {
        RoundSummary(roundID: id, configuration: GameConfiguration(mode: .classic, boardSize: board),
                     attempts: 5 + i % 3, hintsUsed: i % 2, pairCount: board.pairCount,
                     startedAt: Date(timeIntervalSince1970: Double(i) * 100),
                     completedAt: Date(timeIntervalSince1970: Double(i) * 100 + 60))
    }

    func testCompletionIsSavedOnlyOnce() throws {
        let store = InMemoryCompletionHistory()
        let s = summary(1)
        XCTAssertTrue(try store.record(s))
        XCTAssertFalse(try store.record(s))
        XCTAssertEqual(try store.recentRecords().count, 1)
        XCTAssertEqual(try store.totals().roundsCompleted, 1)
    }

    func testKeepsLatest100AndAggregatesEverything() throws {
        let store = InMemoryCompletionHistory()
        for i in 0..<130 { try store.record(summary(i, board: i % 2 == 0 ? .six : .twelve)) }
        let recent = try store.recentRecords()
        XCTAssertEqual(recent.count, 100)
        XCTAssertEqual(recent.first?.completedAt, Date(timeIntervalSince1970: 129 * 100 + 60), "newest first")
        let totals = try store.totals()
        XCTAssertEqual(totals.roundsCompleted, 130)
        XCTAssertEqual(totals.roundsByBoard[6], 65)
        XCTAssertEqual(totals.roundsByBoard[12], 65)
        XCTAssertEqual(totals.pairsMatched, 65 * 3 + 65 * 6)
    }

    func testTrimmedRoundCannotBeRecordedAgain() throws {
        let store = InMemoryCompletionHistory()
        let first = summary(0)
        try store.record(first)
        for i in 1...120 { try store.record(summary(i)) }
        XCTAssertFalse(try store.recentRecords().contains { $0.roundID == first.roundID })
        XCTAssertFalse(try store.record(first), "dedupe survives trimming")
        XCTAssertEqual(try store.totals().roundsCompleted, 121)
    }

    func testResetClearsHistory() throws {
        let store = InMemoryCompletionHistory()
        try store.record(summary(1))
        try store.resetProgress()
        XCTAssertTrue(try store.recentRecords().isEmpty)
        XCTAssertEqual(try store.totals(), ProgressTotals())
    }
}

final class EntitlementResolverTests: XCTestCase {
    let cache = CachedEntitlement(transactionID: 7, verifiedAt: Date(timeIntervalSince1970: 0))

    func testVerifiedActiveUnlocks() {
        let d = EntitlementResolver.resolve(evidence: [.verifiedActive(transactionID: 9)], scanCompleted: true, cached: nil)
        XCTAssertEqual(d.level, .fullGame)
        XCTAssertEqual(d.cache?.transactionID, 9)
    }

    func testRevocationLocksAndClearsCache() {
        let d = EntitlementResolver.resolve(evidence: [.verifiedRevoked(transactionID: 7)], scanCompleted: true, cached: cache)
        XCTAssertEqual(d.level, .starter)
        XCTAssertNil(d.cache)
    }

    func testUnverifiedNeverInventsAccess() {
        let d = EntitlementResolver.resolve(evidence: [.unverified], scanCompleted: true, cached: nil)
        XCTAssertEqual(d.level, .starter)
    }

    func testPreviouslyVerifiedAccessIsPreservedWhenStoreKitCannotAnswer() {
        XCTAssertEqual(EntitlementResolver.resolve(evidence: [], scanCompleted: false, cached: cache).level, .fullGame)
        XCTAssertEqual(EntitlementResolver.resolve(evidence: [.unverified], scanCompleted: true, cached: cache).level, .fullGame)
    }

    func testCompletedEmptyScanLocks() {
        let d = EntitlementResolver.resolve(evidence: [], scanCompleted: true, cached: cache)
        XCTAssertEqual(d.level, .starter)
        XCTAssertNil(d.cache)
    }

    func testAccessPolicy() {
        let starter = ContentAccessPolicy(level: .starter)
        XCTAssertTrue(starter.isAvailable(GameConfiguration(mode: .classic, boardSize: .six)))
        XCTAssertTrue(starter.isAvailable(GameConfiguration(mode: .classic, boardSize: .twelve)))
        XCTAssertFalse(starter.isAvailable(GameConfiguration(mode: .classic, boardSize: .sixteen)))
        XCTAssertFalse(starter.isAvailable(GameConfiguration(mode: .exactPose, boardSize: .six)))
        let full = ContentAccessPolicy(level: .fullGame)
        XCTAssertTrue(GameMode.allCases.allSatisfy { m in BoardSize.allCases.allSatisfy { full.isAvailable(GameConfiguration(mode: m, boardSize: $0)) } })
    }
}

final class ParentalGateTests: XCTestCase {
    func testCorrectAnswerGrants() {
        var rng = SeededGenerator(seed: 1)
        var gate = ParentalGate(challenge: ParentalGateChallenge(lhs: 7, rhs: 8))
        XCTAssertEqual(gate.submit(" 56 ", using: &rng), .granted)
        XCTAssertFalse(ParentalGateChallenge(lhs: 7, rhs: 8).accepts("５６"), "only ASCII 0–9 digits")
        XCTAssertFalse(ParentalGateChallenge(lhs: 7, rhs: 8).accepts("-56"))
        XCTAssertFalse(ParentalGateChallenge(lhs: 7, rhs: 8).accepts("5 6"))
        XCTAssertFalse(ParentalGateChallenge(lhs: 7, rhs: 8).accepts(""))
    }

    func testThreeWrongAnswersRotateChallenge() {
        var rng = SeededGenerator(seed: 1)
        let original = ParentalGateChallenge(lhs: 7, rhs: 8)
        var gate = ParentalGate(challenge: original)
        XCTAssertEqual(gate.submit("1", using: &rng), .incorrect(attemptsRemaining: 2))
        XCTAssertEqual(gate.submit("2", using: &rng), .incorrect(attemptsRemaining: 1))
        XCTAssertEqual(gate.submit("3", using: &rng), .newChallenge)
        XCTAssertNotEqual(gate.challenge, original)
        XCTAssertEqual(gate.failedAttempts, 0)
    }

    func testChallengesAreNotTrivial() {
        var rng = SeededGenerator(seed: 5)
        for _ in 0..<200 {
            let c = ParentalGateChallenge.random(using: &rng)
            XCTAssertTrue((3...9).contains(c.lhs) && (6...9).contains(c.rhs))
            XCTAssertGreaterThanOrEqual(c.answer, 18)
        }
    }

    func testAccessSessionExpires() {
        var session = ParentAccessSession(lifetime: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(session.isActive(now: t0))
        session.grant(now: t0)
        XCTAssertTrue(session.isActive(now: t0.addingTimeInterval(59)))
        XCTAssertFalse(session.isActive(now: t0.addingTimeInterval(61)))
        session.grant(now: t0)
        session.revoke()
        XCTAssertFalse(session.isActive(now: t0))
    }
}

