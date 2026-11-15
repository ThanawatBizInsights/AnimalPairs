import AnimalPairsCore
import StoreKit
import StoreKitTest
import XCTest
@testable import AnimalPairs

/// Exercises purchase states against the local StoreKit configuration
/// (Config/Products.storekit). Runs in the iOS Simulator only.
@MainActor
final class PurchaseTests: XCTestCase {
    private var session: SKTestSession!
    private var defaults: UserDefaults!
    private let productID = AppConfiguration.placeholderProductID

    override func setUp() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/Products.storekit")
        session = try SKTestSession(contentsOf: url)
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
}
