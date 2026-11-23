import AnimalPairsCore
import StoreKit
import StoreKitTest
import XCTest
@testable import AnimalPairs

/// Exercises the one-time "Full Game Unlock" (non-consumable) — purchase,
/// Ask to Buy, cancel, failure, refund, restore, relaunch, reinstall — and
/// offer codes against the local StoreKit configuration
/// (Config/Products.storekit). Runs in the iOS Simulator (run it on an
/// iPhone and an iPad simulator). These are *simulated* StoreKit tests: real
/// App Store behaviour is checked with a sandbox account / TestFlight.
@MainActor
final class PurchaseTests: XCTestCase {
    private var session: SKTestSession!
    private var defaults: UserDefaults!
    /// The Full Game Unlock in Config/Products.storekit (must equal
    /// AP_FULL_UNLOCK_PRODUCT_ID).
    private var productID = AppConfiguration.defaultFullUnlockProductID

    override func setUp() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/Products.storekit")
        session = try SKTestSession(contentsOf: url)
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let products = config?["products"] as? [[String: Any]] ?? []
        XCTAssertEqual(products.count, 1, "exactly one product")
        XCTAssertEqual(products.first?["type"] as? String, "NonConsumable")
        XCTAssertEqual((config?["subscriptionGroups"] as? [Any])?.count ?? 0, 0, "no subscriptions")
        productID = try XCTUnwrap(products.first?["productID"] as? String)
        XCTAssertEqual(productID, AppConfiguration.current.fullUnlockProductID,
                       "Products.storekit and AP_FULL_UNLOCK_PRODUCT_ID must name the same product")
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

    private func buy(_ manager: PurchaseManager) async throws {
        let result = try await XCTUnwrap(manager.product).purchase()
        await manager.handle(result: result)
    }

    private func policy(_ manager: PurchaseManager) -> ContentAccessPolicy {
        ContentAccessPolicy(level: manager.accessLevel)
    }

    /// 6 and 12 Classic free; Classic 16/20 and every Exact Pose board locked.
    private func assertFreeTier(_ manager: PurchaseManager, file: StaticString = #filePath, line: UInt = #line) {
        let p = policy(manager)
        for size in BoardSize.allCases {
            XCTAssertEqual(p.isAvailable(GameConfiguration(mode: .classic, boardSize: size)),
                           size == .six || size == .twelve, "Classic \(size.rawValue)", file: file, line: line)
            XCTAssertFalse(p.isAvailable(GameConfiguration(mode: .exactPose, boardSize: size)),
                           "Exact Pose \(size.rawValue)", file: file, line: line)
        }
    }

    private func assertEverythingUnlocked(_ manager: PurchaseManager, file: StaticString = #filePath, line: UInt = #line) {
        let p = policy(manager)
        for mode in GameMode.allCases {
            for size in BoardSize.allCases {
                XCTAssertTrue(p.isAvailable(GameConfiguration(mode: mode, boardSize: size)), file: file, line: line)
            }
        }
    }

    func testProductIsAOneTimeNonConsumableWithAStoreKitPrice() async throws {
        let manager = await makeManager()
        let product = try XCTUnwrap(manager.product)
        XCTAssertEqual(product.type, .nonConsumable)
        XCTAssertNil(product.subscription, "not a subscription")
        XCTAssertFalse(product.displayPrice.isEmpty, "the app shows StoreKit's localized price")
        // The local test configuration mirrors the App Store Connect price
        // (US$3.99, US storefront). The app never hard-codes it.
        XCTAssertEqual(product.price, Decimal(string: "3.99"))
        XCTAssertTrue(product.displayPrice.contains("3.99"), product.displayPrice)
        XCTAssertEqual(manager.accessLevel, .starter)
    }

    func testFreeTierIsClassicSixAndTwelve() async throws {
        let manager = await makeManager()
        await manager.refreshEntitlements()
        assertFreeTier(manager)
    }

    func testPurchaseUnlocksEverythingAndSurvivesARelaunch() async throws {
        let manager = await makeManager()
        try await buy(manager)
        XCTAssertEqual(manager.flowState, .purchased)
        assertEverythingUnlocked(manager)

        // A new launch honours the verified purchase even before StoreKit answers…
        let relaunched = PurchaseManager(productID: productID, cacheStore: EntitlementCacheStore(defaults: defaults))
        XCTAssertEqual(relaunched.verifiedLevel, .fullGame)
        // …and StoreKit confirms it.
        await relaunched.refreshEntitlements()
        XCTAssertEqual(relaunched.verifiedLevel, .fullGame)
    }

    func testAnotherDeviceOrReinstallWithTheSameAppleAccountIsUnlockedWithoutRestore() async throws {
        let manager = await makeManager()
        try await buy(manager)
        // The same Apple Account on another iPhone/iPad, or a reinstall: no
        // local cache; launch re-reads verified entitlements, no prompt.
        let otherDevice = PurchaseManager(productID: productID,
                                          cacheStore: EntitlementCacheStore(defaults: AppTestSupport.isolatedDefaults()))
        XCTAssertEqual(otherDevice.verifiedLevel, .starter)
        await otherDevice.refreshEntitlements()
        XCTAssertEqual(otherDevice.verifiedLevel, .fullGame)
        XCTAssertEqual(otherDevice.flowState, .idle, "nothing was shown or asked")
    }

    func testAskToBuyIsPendingAndStaysLocked() async throws {
        session.askToBuyEnabled = true
        let manager = await makeManager()
        try await buy(manager)
        XCTAssertEqual(manager.flowState, .pendingApproval)
        assertFreeTier(manager)
    }

    func testCancelledPurchaseStaysLocked() async throws {
        let manager = await makeManager()
        await manager.handle(result: .userCancelled)
        XCTAssertEqual(manager.flowState, .cancelled)
        assertFreeTier(manager)
    }

    func testFailedTransactionStaysLocked() async throws {
        session.failTransactionsEnabled = true
        let manager = await makeManager()
        do {
            try await buy(manager)
        } catch {
            XCTAssertNotEqual(manager.flowState, .purchased)
        }
        assertFreeTier(manager)
    }

    func testRefundRevokesAccess() async throws {
        let manager = await makeManager()
        try await buy(manager)
        assertEverythingUnlocked(manager)
        let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == productID })
        try session.refundTransaction(identifier: transaction.identifier)
        await manager.refreshEntitlements()
        assertFreeTier(manager)
        XCTAssertTrue(manager.wasRefunded, "Parents explains why the game is locked again")
        // A relaunch after the refund stays locked.
        let relaunched = PurchaseManager(productID: productID, cacheStore: EntitlementCacheStore(defaults: defaults))
        await relaunched.refreshEntitlements()
        XCTAssertEqual(relaunched.verifiedLevel, .starter)
    }

    func testNoPurchaseMeansFree() async throws {
        let manager = await makeManager()
        await manager.refreshEntitlements()
        XCTAssertEqual(manager.accessLevel, .starter)
        XCTAssertFalse(manager.wasRefunded)
    }

    func testRetiredSubscriptionCacheIsRemovedAndIgnored() async throws {
        // Development builds kept a test-subscription record under this key.
        defaults.set(Data("{\"transactionID\":1,\"verifiedAt\":0}".utf8), forKey: "purchases.verifiedEntitlement")
        let manager = PurchaseManager(productID: productID, cacheStore: EntitlementCacheStore(defaults: defaults))
        XCTAssertEqual(manager.verifiedLevel, .starter)
        XCTAssertNil(defaults.object(forKey: "purchases.verifiedEntitlement"))
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
        defaults.set(true, forKey: "purchases.fullGameUnlock.verified")   // not a verified record
        defaults.set(true, forKey: "fullGameUnlocked")
        let manager = PurchaseManager(productID: productID, cacheStore: EntitlementCacheStore(defaults: defaults))
        XCTAssertEqual(manager.verifiedLevel, .starter)
    }

    // MARK: Restore Purchases

    func testRestoreAfterReinstallFindsThePurchase() async throws {
        try session.buyProduct(productIdentifier: productID)
        // A reinstall: no local cache at all.
        let manager = PurchaseManager(productID: productID,
                                      cacheStore: EntitlementCacheStore(defaults: AppTestSupport.isolatedDefaults()))
        XCTAssertEqual(manager.verifiedLevel, .starter)
        await manager.restore()
        XCTAssertEqual(manager.flowState, .restored)
        assertEverythingUnlocked(manager)
    }

    func testRestoreWithNothingToRestore() async throws {
        let manager = await makeManager()
        await manager.restore()
        XCTAssertEqual(manager.flowState, .restoreFoundNothing)
        assertFreeTier(manager)
    }

    func testRestoreAfterARefundSaysSo() async throws {
        let manager = await makeManager()
        try await buy(manager)
        let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == productID })
        try session.refundTransaction(identifier: transaction.identifier)
        await manager.restore()
        XCTAssertEqual(manager.flowState, .restoreFoundRefunded)
        assertFreeTier(manager)
    }

    func testRestoreTappedTwiceRunsOnce() async throws {
        try session.buyProduct(productIdentifier: productID)
        let manager = PurchaseManager(productID: productID,
                                      cacheStore: EntitlementCacheStore(defaults: AppTestSupport.isolatedDefaults()))
        async let first: Void = manager.restore()
        async let second: Void = manager.restore()     // ignored: a restore is already running
        _ = await (first, second)
        XCTAssertEqual(manager.flowState, .restored)
        XCTAssertEqual(manager.verifiedLevel, .fullGame)
    }

    func testStoreErrorsBecomeParentMessages() {
        XCTAssertEqual(PurchaseManager.flowState(for: StoreKitError.userCancelled), .cancelled)
        XCTAssertEqual(PurchaseManager.flowState(for: StoreKitError.networkError(URLError(.notConnectedToInternet))),
                       .networkUnavailable)
        XCTAssertEqual(PurchaseManager.flowState(for: URLError(.timedOut)), .networkUnavailable)
    }
}
