import AnimalPairsCore
import StoreKit
import StoreKitTest
import XCTest
@testable import AnimalPairs

/// Exercises the Animal Pairs Plus subscription — purchase, Ask to Buy,
/// cancel, failure, expiry, refund, restore, relaunch — and offer codes
/// against the local StoreKit configuration (Config/Products.storekit). Runs in the iOS
/// Simulator only. These are *simulated* StoreKit tests: a real offer code
/// can only be redeemed against App Store Connect (sandbox codes / TestFlight),
/// see README "Gift codes".
@MainActor
final class PurchaseTests: XCTestCase {
    private var session: SKTestSession!
    private var defaults: UserDefaults!
    /// The Plus subscription in Config/Products.storekit (keep it equal to
    /// AP_PLUS_PRODUCT_ID when you rename it).
    private var productID = AppConfiguration.placeholderProductID

    override func setUp() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/Products.storekit")
        session = try SKTestSession(contentsOf: url)
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let groups = config?["subscriptionGroups"] as? [[String: Any]] ?? []
        XCTAssertEqual(groups.count, 1, "one subscription group")
        let subscriptions = groups.first?["subscriptions"] as? [[String: Any]] ?? []
        XCTAssertEqual(subscriptions.count, 1, "one subscription")
        XCTAssertEqual(subscriptions.first?["recurringSubscriptionPeriod"] as? String, "P1M", "monthly")
        productID = try XCTUnwrap(subscriptions.first?["productID"] as? String)
        XCTAssertEqual(productID, AppConfiguration.current.plusProductID,
                       "Products.storekit and AP_PLUS_PRODUCT_ID must name the same product")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defaults = AppTestSupport.isolatedDefaults()
    }

    override func tearDown() async throws {
        session.clearTransactions()
    }

    private func makeManager(defaults custom: UserDefaults? = nil) async -> PurchaseManager {
        let manager = PurchaseManager(productID: productID,
                                      cacheStore: EntitlementCacheStore(defaults: custom ?? defaults))
        #if DEBUG
        manager.debugMockUnlocked = false
        #endif
        await manager.loadProduct()
        return manager
    }

    private func subscribe(_ manager: PurchaseManager) async throws {
        let result = try await XCTUnwrap(manager.product).purchase()
        await manager.handle(result: result)
    }

    func testProductIsAMonthlySubscriptionWithAStoreKitPrice() async throws {
        let manager = await makeManager()
        let product = try XCTUnwrap(manager.product)
        XCTAssertEqual(product.type, .autoRenewable)
        XCTAssertEqual(product.subscription?.subscriptionPeriod.unit, .month)
        XCTAssertEqual(product.subscription?.subscriptionPeriod.value, 1)
        XCTAssertFalse(product.displayPrice.isEmpty, "the app shows StoreKit's localized price")
        XCTAssertEqual(manager.accessLevel, .starter)
    }

    func testFreePlayersHaveClassicWithSixCards() async throws {
        let manager = await makeManager()
        await manager.refreshEntitlements()
        let policy = ContentAccessPolicy(level: manager.accessLevel)
        XCTAssertEqual(Set(BoardSize.allCases.filter { policy.isAvailable($0) }), [.six])
        XCTAssertEqual(Set(GameMode.allCases.filter { policy.isAvailable($0) }), [.classic])
    }

    func testSubscribingUnlocksAndSurvivesARelaunch() async throws {
        let manager = await makeManager()
        try await subscribe(manager)
        XCTAssertEqual(manager.flowState, .purchased)
        XCTAssertEqual(manager.accessLevel, .fullGame)
        XCTAssertNotNil(manager.plan, "renewal details for Parents")
        XCTAssertEqual(manager.plan?.willAutoRenew, true)

        // A new launch honours the verified period even before StoreKit answers.
        let relaunched = PurchaseManager(productID: productID, cacheStore: EntitlementCacheStore(defaults: defaults))
        XCTAssertEqual(relaunched.verifiedLevel, .fullGame)
        await relaunched.refreshEntitlements()
        XCTAssertEqual(relaunched.verifiedLevel, .fullGame)
    }

    func testAskToBuyIsPendingAndDoesNotUnlock() async throws {
        session.askToBuyEnabled = true
        let manager = await makeManager()
        try await subscribe(manager)
        XCTAssertEqual(manager.flowState, .pendingApproval)
        XCTAssertEqual(manager.accessLevel, .starter)
    }

    func testCancelledPurchaseChangesNothing() async throws {
        let manager = await makeManager()
        await manager.handle(result: .userCancelled)
        XCTAssertEqual(manager.flowState, .cancelled)
        XCTAssertEqual(manager.accessLevel, .starter)
    }

    func testFailedTransactionDoesNotUnlock() async throws {
        session.failTransactionsEnabled = true
        let manager = await makeManager()
        do {
            try await subscribe(manager)
        } catch {
            // Expected: StoreKit reports the simulated failure.
        }
        XCTAssertEqual(manager.accessLevel, .starter)
    }

    func testExpiryRemovesAccess() async throws {
        let manager = await makeManager()
        try await subscribe(manager)
        XCTAssertEqual(manager.accessLevel, .fullGame)
        try session.expireSubscription(productIdentifier: productID)
        await manager.refreshEntitlements()
        XCTAssertEqual(manager.accessLevel, .starter)
        XCTAssertNil(manager.plan)
    }

    func testRefundRevokesAccess() async throws {
        let manager = await makeManager()
        try await subscribe(manager)
        XCTAssertEqual(manager.accessLevel, .fullGame)
        let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == productID })
        try session.refundTransaction(identifier: transaction.identifier)
        await manager.refreshEntitlements()
        XCTAssertEqual(manager.accessLevel, .starter)
    }

    func testRestoreFindsAnExistingSubscription() async throws {
        try session.buyProduct(productIdentifier: productID)        // e.g. bought on another device
        let manager = await makeManager()
        await manager.refreshEntitlements()
        XCTAssertEqual(manager.accessLevel, .fullGame)
    }

    func testRestoreWithNothingToRestore() async throws {
        let manager = await makeManager()
        await manager.restore()
        XCTAssertEqual(manager.flowState, .restoreFoundNothing)
        XCTAssertEqual(manager.accessLevel, .starter)
    }

    func testNoPurchaseMeansFree() async throws {
        let manager = await makeManager()
        await manager.refreshEntitlements()
        XCTAssertEqual(manager.accessLevel, .starter)
    }

    func testAnExpiredCachedPeriodIsNotHonouredOffline() {
        let store = EntitlementCacheStore(defaults: defaults)
        store.save(CachedEntitlement(transactionID: 1, verifiedAt: Date(timeIntervalSinceNow: -40 * 86_400),
                                     expiresAt: Date(timeIntervalSinceNow: -10 * 86_400)))
        XCTAssertEqual(PurchaseManager(productID: productID, cacheStore: store).verifiedLevel, .starter)
        store.save(CachedEntitlement(transactionID: 2, verifiedAt: Date(), expiresAt: Date(timeIntervalSinceNow: 86_400)))
        XCTAssertEqual(PurchaseManager(productID: productID, cacheStore: store).verifiedLevel, .fullGame,
                       "a paid period still running is honoured before StoreKit answers")
    }

    // MARK: Gift codes

    func testClosingTheRedeemSheetWithoutACodeNeverUnlocks() async throws {
        let manager = await makeManager()
        manager.redemptionWait = 0.5
        manager.beginRedemption()
        XCTAssertEqual(manager.flowState, .redeeming)
        XCTAssertTrue(manager.isRedeemSheetPresented)
        await manager.redemptionSheetClosed(.success(()))       // cancelled, or Apple rejected the code
        XCTAssertEqual(manager.flowState, .redeemFoundNothing)
        XCTAssertEqual(manager.verifiedLevel, .starter)
        XCTAssertFalse(manager.isRedeemSheetPresented)
    }

    func testRedeemSheetNetworkFailureIsReportedAndDoesNotUnlock() async throws {
        let manager = await makeManager()
        manager.redemptionWait = 0.5
        manager.beginRedemption()
        await manager.redemptionSheetClosed(.failure(URLError(.notConnectedToInternet)))
        XCTAssertEqual(manager.flowState, .networkUnavailable)
        XCTAssertEqual(manager.verifiedLevel, .starter)
    }

    func testRedemptionUnlocksOnlyOnceStoreKitHasAVerifiedTransaction() async throws {
        let manager = await makeManager()
        manager.redemptionWait = 3
        manager.beginRedemption()
        // What a successful redemption delivers: a transaction for the unlock product.
        try session.buyProduct(productIdentifier: productID)
        await manager.redemptionSheetClosed(.success(()))
        XCTAssertEqual(manager.flowState, .redeemed)
        XCTAssertEqual(manager.verifiedLevel, .fullGame)
    }

    func testSheetClosedTwiceIsCheckedOnce() async throws {
        let manager = await makeManager()
        manager.redemptionWait = 0.2
        manager.beginRedemption()
        await manager.redemptionSheetClosed(.success(()))
        let state = manager.flowState
        await manager.redemptionSheetClosed(.failure(URLError(.notConnectedToInternet)))
        XCTAssertEqual(manager.flowState, state, "a second close report is ignored")
    }

    func testRedemptionOutsideTheAppUnlocksOnReturn() async throws {
        let manager = await makeManager()
        manager.start()
        XCTAssertEqual(manager.verifiedLevel, .starter)
        // Redeemed in the App Store app (or approved elsewhere) while the game was in the background.
        try session.buyProduct(productIdentifier: productID)
        manager.appBecameActive()
        for _ in 0..<30 where manager.verifiedLevel != .fullGame {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(manager.verifiedLevel, .fullGame)
    }

    func testOfflineLaunchKeepsAVerifiedUnlockUntilStoreKitAnswers() async throws {
        let manager = await makeManager()
        await manager.handle(result: try await XCTUnwrap(manager.product).purchase())
        XCTAssertEqual(manager.verifiedLevel, .fullGame)
        // Before (or without) a StoreKit answer, only a previously verified unlock is honoured.
        let offline = PurchaseManager(productID: productID, cacheStore: EntitlementCacheStore(defaults: defaults))
        XCTAssertEqual(offline.verifiedLevel, .fullGame)
        let neverVerified = PurchaseManager(productID: productID,
                                            cacheStore: EntitlementCacheStore(defaults: AppTestSupport.isolatedDefaults()))
        XCTAssertEqual(neverVerified.verifiedLevel, .starter)
    }

    func testAPlainUserDefaultsFlagNeverUnlocks() async throws {
        defaults.set(true, forKey: "purchases.verifiedEntitlement")   // not a verified record
        defaults.set(true, forKey: "fullGameUnlocked")
        let manager = PurchaseManager(productID: productID, cacheStore: EntitlementCacheStore(defaults: defaults))
        XCTAssertEqual(manager.verifiedLevel, .starter)
    }

    func testRestoreAfterReinstallFindsThePurchase() async throws {
        try session.buyProduct(productIdentifier: productID)
        // A reinstall: no local cache at all.
        let manager = PurchaseManager(productID: productID,
                                      cacheStore: EntitlementCacheStore(defaults: AppTestSupport.isolatedDefaults()))
        XCTAssertEqual(manager.verifiedLevel, .starter)
        await manager.restore()
        XCTAssertEqual(manager.flowState, .restored)
        XCTAssertEqual(manager.verifiedLevel, .fullGame)
    }
}
