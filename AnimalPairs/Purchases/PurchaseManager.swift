import AnimalPairsCore
import Foundation
import Observation
import StoreKit
// `PurchaseAction` (the value of `@Environment(\.purchase)`) lives in the
// StoreKit–SwiftUI cross-import overlay, which is only visible when a file
// imports both StoreKit and SwiftUI. SwiftUI also declares `Transaction`
// (for animations), so StoreKit transactions are written `StoreKit.Transaction`.
import SwiftUI

/// Persists the ID of the last *verified* Full Game Unlock transaction.
struct EntitlementCacheStore {
    private let defaults: UserDefaults
    private let key = "purchases.fullGameUnlock.verified"
    /// Earlier development builds (a monthly test subscription, local and
    /// sandbox only) used this key. It is never read; it is removed.
    static let retiredKeys = ["purchases.verifiedEntitlement"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.retiredKeys.forEach(defaults.removeObject(forKey:))
    }

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

/// StoreKit 2 handling for "Full Game Unlock": one non-consumable in-app
/// purchase, bought once, never expires (product ID from `AppConfiguration`,
/// i.e. the build setting `AP_FULL_UNLOCK_PRODUCT_ID`). What it unlocks is
/// defined in AnimalPairsCore (`FullGameUnlock.features`).
///
/// * Ownership comes only from verified StoreKit transactions for that
///   product (`EntitlementResolver`). Unverified transactions never unlock;
///   refunds and revocations remove access.
/// * Re-read at launch, on returning to the foreground, after a purchase,
///   after Restore, after the offer-code sheet, and whenever
///   `StoreKit.Transaction.updates` reports a change (Ask to Buy approvals,
///   purchases on another device, refunds).
/// * Works on every iPhone and iPad signed in to the purchasing Apple Account
///   (StoreKit syncs the transaction); Restore Purchases forces a sync.
/// * The cached verified transaction ID keeps an offline launch unlocked; it
///   is never proof of purchase on its own.
/// * The price comes from StoreKit (`displayPrice`), never from the app.
/// * Every purchase action is reached only from Parents, behind the gate.
/// * Resetting game progress never touches this state.
@MainActor
@Observable
final class PurchaseManager {
    let productID: String
    private(set) var product: Product?
    private(set) var verifiedLevel: AccessLevel
    private(set) var flowState: PurchaseFlowState = .idle
    private(set) var lastStoreError: String?
    /// True when the newest verified transaction for the unlock was refunded
    /// or revoked by Apple (Parents explains why the game is locked again).
    private(set) var wasRefunded = false
    /// Drives `.offerCodeRedemption(isPresented:)` in the Parents area.
    var isRedeemSheetPresented = false
    @ObservationIgnored private var unlockedBeforeRedemption = false
    /// How long to wait after the redeem sheet closes for StoreKit to deliver
    /// the verified transaction before saying nothing was redeemed.
    @ObservationIgnored var redemptionWait: TimeInterval = 8

    private let cacheStore: EntitlementCacheStore
    private var cache: CachedEntitlement?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    /// Called on the main actor whenever the level the game uses changes
    /// (StoreKit confirming or removing the purchase, Restore, a refund).
    @ObservationIgnored var onAccessLevelChange: ((AccessLevel) -> Void)?

    #if DEBUG
    /// DEBUG-only simulated unlock for UI work without StoreKit. This
    /// property does not exist in Release builds, so it cannot unlock them.
    var debugMockUnlocked: Bool {
        didSet {
            UserDefaults.standard.set(debugMockUnlocked, forKey: "debug.mockUnlocked")
            if debugMockUnlocked != oldValue { onAccessLevelChange?(accessLevel) }
        }
    }
    #endif

    init(productID: String, cacheStore: EntitlementCacheStore = EntitlementCacheStore()) {
        self.productID = productID
        self.cacheStore = cacheStore
        // Until StoreKit answers, honour a previously *verified* purchase.
        let cached = cacheStore.load()
        self.cache = cached
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
            try await fetchProduct()
            flowState = product == nil ? .productUnavailable : .idle
        } catch {
            flowState = Self.isNetworkProblem(error) ? .networkUnavailable : .productUnavailable
        }
    }

    /// Loads the product without changing the visible flow state.
    private func fetchProduct() async throws {
        do {
            product = try await Product.products(for: [productID]).first
            lastStoreError = nil
        } catch {
            lastStoreError = error.localizedDescription
            throw error
        }
    }

    /// Scans the verified current entitlements and applies the pure resolver.
    /// Reading entitlements never shows an Apple Account prompt.
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
        wasRefunded = verifiedLevel == .fullGame ? false : await latestTransactionWasRefunded()
    }

    /// `currentEntitlements` leaves refunded purchases out; the newest
    /// verified transaction tells whether there was one.
    private func latestTransactionWasRefunded() async -> Bool {
        guard case .verified(let transaction)? = await StoreKit.Transaction.latest(for: productID),
              Self.isUnlock(transaction, productID: productID) else { return false }
        return transaction.revocationDate != nil
    }

    /// Runs a purchase through SwiftUI's `PurchaseAction` so StoreKit can
    /// present its sheet in the right scene. Called only from Parents.
    func purchase(using action: PurchaseAction) async {
        guard !flowState.isBusy else { return }          // one request at a time
        guard verifiedLevel != .fullGame else { return } // already owned
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

    /// A parent's explicit Restore Purchases (Parents area only, behind the
    /// adult gate): `AppStore.sync()` may ask for the Apple Account password,
    /// so nothing else in the app calls it. Launch and returning to the app
    /// only re-read entitlements, which never shows a prompt.
    ///
    /// Access changes only from the verified entitlements read afterwards; a
    /// failed or cancelled sync leaves the current access as it was.
    func restore() async {
        guard !flowState.isBusy else { return }        // one request at a time
        flowState = .restoring
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            flowState = RestoreOutcome.resolve(owned: verifiedLevel == .fullGame, refunded: wasRefunded)
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
    /// redeemed, a purchase approved or a refund granted outside the app.
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
        // Re-read everything rather than trusting this one transaction: an
        // update may be a refund of an earlier purchase.
        await refreshEntitlements()
        if transaction.revocationDate == nil, verifiedLevel == .fullGame {
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
        wasRefunded = false
    }

    private func apply(_ decision: EntitlementDecision) {
        let before = accessLevel
        verifiedLevel = decision.level
        cache = decision.cache
        cacheStore.save(decision.cache)
        if accessLevel != before { onAccessLevelChange?(accessLevel) }
    }
}
