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

    func testTheUnlockNeverExpires() {
        let longAgo = CachedEntitlement(transactionID: 3, verifiedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(EntitlementResolver.resolve(evidence: [], scanCompleted: false, cached: longAgo,
                                                   now: Date(timeIntervalSince1970: 4_000_000_000)).level, .fullGame,
                       "a one-time purchase verified years ago still counts before StoreKit answers")
    }

    func testRefundAfterPurchaseLocks() {
        let d = EntitlementResolver.resolve(evidence: [.verifiedRevoked(transactionID: 5)], scanCompleted: false, cached: cache)
        XCTAssertEqual(d.level, .starter, "a verified refund wins even over a cached unlock")
        XCTAssertNil(d.cache)
    }

    func testRestoreOutcomes() {
        XCTAssertEqual(RestoreOutcome.resolve(owned: true, refunded: false), .restored)
        XCTAssertEqual(RestoreOutcome.resolve(owned: false, refunded: false), .restoreFoundNothing)
        XCTAssertEqual(RestoreOutcome.resolve(owned: false, refunded: true), .restoreFoundRefunded)
        XCTAssertFalse(PurchaseFlowState.restoreFoundRefunded.isBusy)
    }

    func testClosingTheRedeemSheetAloneNeverUnlocks() {
        XCTAssertEqual(RedemptionOutcome.resolve(unlockedBefore: false, verifiedUnlockedNow: false,
                                                 sheetFailedForNetwork: false), .redeemFoundNothing)
        XCTAssertEqual(RedemptionOutcome.resolve(unlockedBefore: false, verifiedUnlockedNow: false,
                                                 sheetFailedForNetwork: true), .networkUnavailable)
        XCTAssertEqual(RedemptionOutcome.resolve(unlockedBefore: false, verifiedUnlockedNow: true,
                                                 sheetFailedForNetwork: false), .redeemed)
        XCTAssertEqual(RedemptionOutcome.resolve(unlockedBefore: true, verifiedUnlockedNow: true,
                                                 sheetFailedForNetwork: false), .restored,
                       "already owned: nothing new was redeemed")
    }

    func testBusyStatesBlockOtherStoreActions() {
        let busy: [PurchaseFlowState] = [.purchasing, .restoring, .redeeming, .checkingRedemption]
        XCTAssertTrue(busy.allSatisfy(\.isBusy))
        let idle: [PurchaseFlowState] = [.idle, .redeemed, .redeemFoundNothing, .networkUnavailable, .cancelled, .purchased]
        XCTAssertTrue(idle.allSatisfy { !$0.isBusy })
    }

    func testFullGameUnlocksExactlyThePremiumFeatures() {
        let starter = ContentAccessPolicy(level: .starter)
        let full = ContentAccessPolicy(level: .fullGame)
        // Free for everyone: Classic mode with 6 or 12 cards.
        XCTAssertEqual(Set(GameMode.allCases.filter { starter.isAvailable($0) }), [.classic])
        XCTAssertEqual(Set(BoardSize.allCases.filter { starter.isAvailable($0) }), [.six, .twelve])
        XCTAssertTrue(starter.grantedFeatures.isEmpty)
        // Full Game Unlock: everything that ships today.
        XCTAssertEqual(Set(GameMode.allCases.filter { full.isAvailable($0) }), Set(GameMode.allCases))
        XCTAssertEqual(Set(BoardSize.allCases.filter { full.isAvailable($0) }), Set(BoardSize.allCases))
    }

    /// The purchase's definition is explicit. When a future theme adds a
    /// `PremiumFeature`, this test fails until someone decides deliberately
    /// whether Full Game Unlock includes it.
    func testFullGameUnlockDefinitionIsDeliberate() {
        XCTAssertEqual(FullGameUnlock.features, [.exactPoseMode, .sixteenCardBoard, .twentyCardBoard, .extraPoses])
        XCTAssertEqual(Set(PremiumFeature.allCases), FullGameUnlock.features,
                       "a new PremiumFeature needs a deliberate decision about which product grants it")
    }

    func testAccessPolicy() {
        let starter = ContentAccessPolicy(level: .starter)
        XCTAssertTrue(starter.isAvailable(GameConfiguration(mode: .classic, boardSize: .six)))
        XCTAssertTrue(starter.isAvailable(GameConfiguration(mode: .classic, boardSize: .twelve)))
        XCTAssertFalse(starter.isAvailable(GameConfiguration(mode: .classic, boardSize: .sixteen)))
        XCTAssertFalse(starter.isAvailable(GameConfiguration(mode: .classic, boardSize: .twenty)))
        for size in BoardSize.allCases {
            XCTAssertFalse(starter.isAvailable(GameConfiguration(mode: .exactPose, boardSize: size)),
                           "Exact Pose is locked at every size, including \(size.rawValue)")
        }
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
