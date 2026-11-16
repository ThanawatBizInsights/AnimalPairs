import AnimalPairsCore
import Foundation
import Observation
import StoreKit
// `PurchaseAction` (the value of `@Environment(\.purchase)`) lives in the
// StoreKit–SwiftUI cross-import overlay, which is only visible when a file
// imports both StoreKit and SwiftUI. SwiftUI also declares `Transaction`
// (for animations), so StoreKit transactions are written `StoreKit.Transaction`.
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

/// StoreKit 2 handling for the single non-consumable "Full Game Unlock".
///
/// Verified StoreKit 2 transactions are the only source of ownership; the
/// small cache below only bridges the moment before StoreKit answers (and
/// offline launches) and is replaced by every completed StoreKit scan.
///
/// * Ways to own it: buy it, redeem an Apple offer code (gift code) in the
///   App Store's own sheet — inside the app or outside it — or Restore.
///   All three arrive as the same verified transaction for `productID`.
/// * Entitlements are re-read at launch, on returning to the foreground,
///   after a purchase, after the redeem sheet closes and on Restore, and
///   `StoreKit.Transaction.updates` is observed for the app's lifetime.
/// * Closing the redeem sheet never unlocks anything by itself.
/// * Prices come from `Product.displayPrice` (localized by the App Store).
/// * Access is delivered before a verified transaction is finished.
/// * Unverified transactions never grant access.
/// * Revocations (refunds) remove access; `StoreKit.Transaction.updates` is observed
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
    /// Drives `.offerCodeRedemption(isPresented:)` in the Parents area.
    var isRedeemSheetPresented = false
    @ObservationIgnored private var unlockedBeforeRedemption = false
    /// How long to wait after the redeem sheet closes for StoreKit to deliver
    /// the verified transaction before saying nothing was redeemed.
    @ObservationIgnored var redemptionWait: TimeInterval = 8

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
            for await update in StoreKit.Transaction.updates {
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
            flowState = Self.isNetworkProblem(error) ? .networkUnavailable : .productUnavailable
        }
    }

    /// Scans current entitlements and applies the pure resolver.
    func refreshEntitlements() async {
        var evidence: [EntitlementEvidence] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction) where Self.isUnlock(transaction, productID: productID):
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
            flowState = Self.flowState(for: error)
        }
    }

    func handle(result: Product.PurchaseResult) async {
        switch result {
        case .success(.verified(let transaction)):
            guard Self.isUnlock(transaction, productID: productID), transaction.revocationDate == nil else {
                // Some other product, or already refunded: never unlocks.
                await transaction.finish()
                flowState = .verificationFailed
                return
            }
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
            flowState = Self.flowState(for: error)
        }
    }

    // MARK: Gift codes (Apple offer codes)

    /// Opens Apple's offer-code redemption sheet. Apple checks the code
    /// (valid, expired, already used, eligible) inside its own sheet.
    func beginRedemption() {
        guard !flowState.isBusy else { return }
        unlockedBeforeRedemption = verifiedLevel == .fullGame
        flowState = .redeeming
        isRedeemSheetPresented = true
    }

    /// Called when the sheet closes, whatever happened in it. Unlocks only
    /// if StoreKit now has a verified transaction for the unlock product.
    func redemptionSheetClosed(_ result: Result<Void, Error>) async {
        // Reported once per sheet, whether by its completion or by a dismissal.
        guard flowState == .redeeming else { return }
        isRedeemSheetPresented = false
        flowState = .checkingRedemption
        var networkProblem = false
        if case .failure(let error) = result { networkProblem = Self.isNetworkProblem(error) }
        await refreshEntitlements()
        // A redemption's transaction can arrive through `updates` a moment
        // after the sheet closes; wait briefly for it.
        let deadline = Date().addingTimeInterval(redemptionWait)
        while verifiedLevel != .fullGame && Date() < deadline && flowState == .checkingRedemption {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if verifiedLevel != .fullGame { await refreshEntitlements() }
        }
        guard flowState == .checkingRedemption else { return }   // `updates` already reported it
        flowState = RedemptionOutcome.resolve(unlockedBefore: unlockedBeforeRedemption,
                                              verifiedUnlockedNow: verifiedLevel == .fullGame,
                                              sheetFailedForNetwork: networkProblem)
    }

    // MARK: Foreground

    /// Called when the app becomes active again, e.g. after a code was
    /// redeemed or a purchase approved outside the app.
    func appBecameActive() {
        guard updatesTask != nil, !flowState.isBusy else { return }
        Task { await refreshEntitlements() }
    }

    func clearFlowMessage() {
        if flowState != .purchasing && flowState != .restoring { flowState = .idle }
    }

    // MARK: Private

    /// Every transaction StoreKit reports while the app runs: purchases
    /// approved later (Ask to Buy), codes redeemed in the App Store or in the
    /// sheet, purchases on another device, refunds and revocations.
    /// Unverified transactions are ignored and never finished, so StoreKit
    /// can deliver them again once they verify.
    private func handle(update: VerificationResult<StoreKit.Transaction>, productID: String) async {
        guard case .verified(let transaction) = update, Self.isUnlock(transaction, productID: productID) else { return }
        if transaction.revocationDate != nil {
            apply(EntitlementResolver.resolve(evidence: [.verifiedRevoked(transactionID: transaction.id)],
                                              scanCompleted: true, cached: cache))
            // Another, still valid transaction (e.g. a later purchase) may exist.
            await refreshEntitlements()
        } else {
            deliver(transaction)
            switch flowState {
            case .pendingApproval: flowState = .purchased
            case .redeeming, .checkingRedemption:
                flowState = unlockedBeforeRedemption ? .restored : .redeemed
            default: break
            }
        }
        await transaction.finish()
    }

    /// The unlock is the configured non-consumable and nothing else.
    nonisolated static func isUnlock(_ transaction: StoreKit.Transaction, productID: String) -> Bool {
        transaction.productID == productID && transaction.productType == .nonConsumable
    }

    nonisolated static func isNetworkProblem(_ error: Error) -> Bool {
        if let storeError = error as? StoreKitError, case .networkError = storeError { return true }
        if error is URLError { return true }
        return (error as NSError).domain == NSURLErrorDomain
    }

    nonisolated static func flowState(for error: Error) -> PurchaseFlowState {
        if isNetworkProblem(error) { return .networkUnavailable }
        if let storeError = error as? StoreKitError {
            switch storeError {
            case .userCancelled: return .cancelled
            case .notAvailableInStorefront: return .productUnavailable
            default: break
            }
        }
        return .failed(error.localizedDescription)
    }

    private func deliver(_ transaction: StoreKit.Transaction) {
        apply(EntitlementResolver.resolve(evidence: [.verifiedActive(transactionID: transaction.id)],
                                          scanCompleted: true, cached: cache))
    }

    private func apply(_ decision: EntitlementDecision) {
        verifiedLevel = decision.level
        cache = decision.cache
        cacheStore.save(decision.cache)
    }
}
