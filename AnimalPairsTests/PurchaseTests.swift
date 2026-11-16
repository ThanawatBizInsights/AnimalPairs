import AnimalPairsCore
import StoreKit
import StoreKitTest
import XCTest
@testable import AnimalPairs

/// Exercises purchase, restore and gift-code (offer code) states against the
/// local StoreKit configuration (Config/Products.storekit). Runs in the iOS
/// Simulator only. These are *simulated* StoreKit tests: a real offer code
/// can only be redeemed against App Store Connect (sandbox codes / TestFlight),
/// see README "Gift codes".
@MainActor
final class PurchaseTests: XCTestCase {
    private var session: SKTestSession!
    private var defaults: UserDefaults!
    /// The unlock product in Config/Products.storekit (keep it equal to
    /// AP_FULL_UNLOCK_PRODUCT_ID when you rename it).
    private var productID = AppConfiguration.placeholderProductID

    override func setUp() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/Products.storekit")
        session = try SKTestSession(contentsOf: url)
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let products = config?["products"] as? [[String: Any]] ?? []
        productID = try XCTUnwrap(products.first { $0["type"] as? String == "NonConsumable" }?["productID"] as? String)
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

    private func makeManager() async -> PurchaseManager {
        let manager = PurchaseManager(productID: productID, cacheStore: EntitlementCacheStore(defaults: defaults))
        #if DEBUG
        manager.debugMockUnlocked = false
        #endif
        await manager.loadProduct()
        return manager
    }

    func testProductLoadsWithLocalizedPrice() async throws {
        let manager = await makeManager()
        let product = try XCTUnwrap(manager.product)
        XCTAssertEqual(product.type, .nonConsumable)
        XCTAssertFalse(product.displayPrice.isEmpty)
        XCTAssertEqual(manager.accessLevel, .starter)
    }

    func testVerifiedPurchaseUnlocksAndPersists() async throws {
        let manager = await makeManager()
        let result = try await XCTUnwrap(manager.product).purchase()
        await manager.handle(result: result)
        XCTAssertEqual(manager.flowState, .purchased)
        XCTAssertEqual(manager.accessLevel, .fullGame)

        // A new launch honours the verified unlock even before StoreKit answers.
        let relaunched = PurchaseManager(productID: productID, cacheStore: EntitlementCacheStore(defaults: defaults))
        XCTAssertEqual(relaunched.verifiedLevel, .fullGame)
        await relaunched.refreshEntitlements()
        XCTAssertEqual(relaunched.verifiedLevel, .fullGame)
    }

    func testAskToBuyIsPendingAndDoesNotUnlock() async throws {
        session.askToBuyEnabled = true
        let manager = await makeManager()
        let result = try await XCTUnwrap(manager.product).purchase()
        await manager.handle(result: result)
        XCTAssertEqual(manager.flowState, .pendingApproval)
        XCTAssertEqual(manager.accessLevel, .starter)
    }

    func testFailedTransactionDoesNotUnlock() async throws {
        session.failTransactionsEnabled = true
        let manager = await makeManager()
        do {
            let result = try await XCTUnwrap(manager.product).purchase()
            await manager.handle(result: result)
        } catch {
            // Expected: StoreKit reports the simulated failure.
        }
        XCTAssertEqual(manager.accessLevel, .starter)
    }

    func testRefundRevokesAccess() async throws {
        let manager = await makeManager()
        let result = try await XCTUnwrap(manager.product).purchase()
        await manager.handle(result: result)
        XCTAssertEqual(manager.accessLevel, .fullGame)

        let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == productID })
        try session.refundTransaction(identifier: transaction.identifier)
        await manager.refreshEntitlements()
        XCTAssertEqual(manager.accessLevel, .starter)
    }

    func testRestoreFindsExistingPurchase() async throws {
        try session.buyProduct(productIdentifier: productID)
        let manager = await makeManager()
        await manager.refreshEntitlements()
        XCTAssertEqual(manager.accessLevel, .fullGame)
    }

    func testNoPurchaseMeansStarter() async throws {
        let manager = await makeManager()
        await manager.refreshEntitlements()
        XCTAssertEqual(manager.accessLevel, .starter)
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
