import AnimalPairsCore
import Foundation
import Observation
import StoreKit
// `PurchaseAction` (the value of `@Environment(\.purchase)`) lives in the
// StoreKit–SwiftUI cross-import overlay, which is only visible when a file
// imports both StoreKit and SwiftUI.
import SwiftUI

/// Persists the last access granted from a *verified* transaction.
struct EntitlementCacheStore {
    private let defaults: UserDefaults
    private let key = "purchases.verifiedEntitlement"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> CachedEntitlement? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(CachedEntitlement.self, from: $0) }
    }

    func save(_ value: CachedEntitlement?) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// StoreKit 2 handling for the single non-consumable full-game unlock.
///
/// * Prices come from `Product.displayPrice` (localized by the App Store).
/// * Access is delivered before a verified transaction is finished.
/// * Unverified transactions never grant access.
/// * Revocations (refunds) remove access; `Transaction.updates` is observed
///   for the lifetime of the app.
/// * Resetting game progress never touches this state.
@MainActor
@Observable
final class PurchaseManager {
    let productID: String
    private(set) var product: Product?
    private(set) var verifiedLevel: AccessLevel
    private(set) var flowState: PurchaseFlowState = .idle
    private(set) var lastStoreError: String?

    private let cacheStore: EntitlementCacheStore
    private var cache: CachedEntitlement?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    #if DEBUG
    /// DEBUG-only simulated unlock for UI work without StoreKit. This
    /// property does not exist in Release builds, so it cannot unlock them.
    var debugMockUnlocked: Bool {
        didSet { UserDefaults.standard.set(debugMockUnlocked, forKey: "debug.mockUnlocked") }
    }
    #endif

    init(productID: String, cacheStore: EntitlementCacheStore = EntitlementCacheStore()) {
        self.productID = productID
        self.cacheStore = cacheStore
        let cached = cacheStore.load()
        self.cache = cached
        // Until StoreKit answers, honour a previously *verified* unlock only.
        self.verifiedLevel = cached == nil ? .starter : .fullGame
        #if DEBUG
        self.debugMockUnlocked = UserDefaults.standard.bool(forKey: "debug.mockUnlocked")
        #endif
    }

    /// The level the game uses.
    var accessLevel: AccessLevel {
        #if DEBUG
        if debugMockUnlocked { return .fullGame }
        #endif
        return verifiedLevel
    }

    var isUnlocked: Bool { accessLevel == .fullGame }

    func start() {
        guard updatesTask == nil else { return }
        let productID = productID
        updatesTask = Task.detached(priority: .background) { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update: update, productID: productID)
            }
        }
        Task {
            await refreshEntitlements()
            await loadProduct()
        }
    }

    func loadProduct() async {
        if product != nil { return }
        flowState = .loadingProducts
        do {
            let products = try await Product.products(for: [productID])
            product = products.first
            flowState = product == nil ? .productUnavailable : .idle
            lastStoreError = nil
        } catch {
            lastStoreError = error.localizedDescription
            flowState = .productUnavailable
        }
    }

    /// Scans current entitlements and applies the pure resolver.
    func refreshEntitlements() async {
        var evidence: [EntitlementEvidence] = []
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction) where transaction.productID == productID:
                evidence.append(transaction.revocationDate == nil
                                ? .verifiedActive(transactionID: transaction.id)
                                : .verifiedRevoked(transactionID: transaction.id))
            case .unverified(let transaction, _) where transaction.productID == productID:
                evidence.append(.unverified)
            default:
                continue
            }
        }
        apply(EntitlementResolver.resolve(evidence: evidence, scanCompleted: true, cached: cache))
    }

    /// Runs a purchase through SwiftUI's `PurchaseAction` so StoreKit can
    /// present its sheet in the right scene.
    func purchase(using action: PurchaseAction) async {
        guard let product else {
            flowState = .productUnavailable
            return
        }
        flowState = .purchasing
        do {
            let result = try await action(product)
            await handle(result: result)
        } catch {
            flowState = .failed(error.localizedDescription)
        }
    }

    func handle(result: Product.PurchaseResult) async {
        switch result {
        case .success(.verified(let transaction)):
            deliver(transaction)
            await transaction.finish()
            flowState = .purchased
        case .success(.unverified):
            // Not finished: StoreKit may redeliver it once verifiable.
            flowState = .verificationFailed
        case .pending:
            flowState = .pendingApproval
        case .userCancelled:
            flowState = .cancelled
        @unknown default:
            flowState = .failed("unknown")
        }
    }

    func restore() async {
        flowState = .restoring
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            flowState = verifiedLevel == .fullGame ? .restored : .restoreFoundNothing
        } catch StoreKitError.userCancelled {
            flowState = .cancelled
        } catch {
            flowState = .failed(error.localizedDescription)
        }
    }

    func clearFlowMessage() {
        if flowState != .purchasing && flowState != .restoring { flowState = .idle }
    }

    // MARK: Private

    private func handle(update: VerificationResult<Transaction>, productID: String) async {
        guard case .verified(let transaction) = update, transaction.productID == productID else { return }
        if transaction.revocationDate != nil {
            apply(EntitlementResolver.resolve(evidence: [.verifiedRevoked(transactionID: transaction.id)],
                                              scanCompleted: true, cached: cache))
        } else {
            deliver(transaction)
            if flowState == .pendingApproval { flowState = .purchased }
        }
        await transaction.finish()
    }

    private func deliver(_ transaction: Transaction) {
        apply(EntitlementResolver.resolve(evidence: [.verifiedActive(transactionID: transaction.id)],
                                          scanCompleted: true, cached: cache))
    }

    private func apply(_ decision: EntitlementDecision) {
        verifiedLevel = decision.level
        cache = decision.cache
        cacheStore.save(decision.cache)
    }
}
