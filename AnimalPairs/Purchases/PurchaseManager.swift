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

/// StoreKit 2 handling for "Animal Pairs Plus", one auto-renewable monthly
/// subscription (product ID from `AppConfiguration`, i.e. the build setting
/// `AP_PLUS_PRODUCT_ID`).
///
/// * Plus access comes only from verified StoreKit transactions whose
///   subscription period has not ended, or a verified status of "subscribed"
///   / "in billing grace period" (`EntitlementResolver`). Unverified
///   transactions never grant access; refunds and revocations remove it.
/// * Re-read at launch, on returning to the foreground, after a purchase,
///   after Restore, after the offer-code sheet, whenever
///   `StoreKit.Transaction.updates` reports a change (renewals, purchases on
///   another device, Ask to Buy approvals, refunds) and when the current
///   period ends while the app is open.
/// * Works on every device signed in to the purchasing Apple Account
///   (StoreKit syncs the entitlement); Restore Purchases forces a sync.
/// * A cached verified period bridges offline launches until that period's
///   end — never longer. A completed StoreKit scan is authoritative.
/// * Prices and the billing period come from StoreKit (`displayPrice`,
///   `subscriptionPeriod`), never from the app.
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
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    /// What Parents shows about the active subscription (nil when inactive).
    private(set) var plan: PlanStatus?
    /// Why Plus is not active although this Apple Account has had it (ended,
    /// refunded, payment problem). Parents-only information; never grants or
    /// removes access by itself.
    private(set) var lapse: SubscriptionLapse?

    struct PlanStatus: Equatable {
        /// End of the current paid period (renewal date when it auto-renews).
        var periodEnd: Date?
        var willAutoRenew: Bool
        var inGracePeriod: Bool
    }

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
        // Until StoreKit answers, honour a previously *verified* period only,
        // and only until that period ends.
        let cached = cacheStore.load().flatMap { $0.isValid(at: Date()) ? $0 : nil }
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
            await refreshEntitlements()     // again with the subscription status
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

    /// Scans current entitlements (and, when the product is loaded, the
    /// verified subscription status) and applies the pure resolver.
    func refreshEntitlements() async {
        var evidence: [EntitlementEvidence] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction) where Self.isUnlock(transaction, productID: productID):
                guard !transaction.isUpgraded else { continue }     // superseded by another transaction
                evidence.append(transaction.revocationDate == nil
                                ? .verifiedActive(transactionID: transaction.id, expiresAt: transaction.expirationDate)
                                : .verifiedRevoked(transactionID: transaction.id))
            case .unverified(let transaction, _) where transaction.productID == productID:
                evidence.append(.unverified)
            default:
                continue
            }
        }
        // The renewal status adds the billing grace period and the "renews /
        // ends on" details. A network failure here is not evidence of anything.
        var states: [SubscriptionRenewalState] = []
        var newPlan: PlanStatus?
        if let statuses = try? await product?.subscription?.status {
            for status in statuses {
                guard case .verified(let renewal) = status.renewalInfo,
                      case .verified(let transaction) = status.transaction,
                      transaction.productID == productID else { continue }
                let state = Self.renewalState(status.state)
                states.append(state)
                if state == .subscribed || state == .inGracePeriod {
                    newPlan = PlanStatus(periodEnd: transaction.expirationDate, willAutoRenew: renewal.willAutoRenew,
                                         inGracePeriod: state == .inGracePeriod)
                }
            }
        }
        apply(EntitlementResolver.resolve(evidence: evidence, renewalStates: states, scanCompleted: true, cached: cache))
        if verifiedLevel == .fullGame {
            plan = newPlan ?? plan ?? PlanStatus(periodEnd: cache?.expiresAt, willAutoRenew: true, inGracePeriod: false)
            lapse = nil
        } else {
            plan = nil
            lapse = SubscriptionLapseResolver.resolve(isActive: false, latest: await latestVerifiedTransaction(),
                                                      renewalStates: states)
        }
    }

    /// The newest verified transaction for the subscription, including expired
    /// and refunded ones (`currentEntitlements` leaves those out).
    private func latestVerifiedTransaction() async -> LatestSubscriptionTransaction? {
        guard case .verified(let transaction)? = await StoreKit.Transaction.latest(for: productID),
              Self.isUnlock(transaction, productID: productID) else { return nil }
        return LatestSubscriptionTransaction(expiresAt: transaction.expirationDate, revokedAt: transaction.revocationDate)
    }

    nonisolated static func renewalState(_ state: Product.SubscriptionInfo.RenewalState) -> SubscriptionRenewalState {
        switch state {
        case .subscribed: .subscribed
        case .inGracePeriod: .inGracePeriod
        case .inBillingRetryPeriod: .inBillingRetry
        case .revoked: .revoked
        default: .expired
        }
    }

    /// Runs a purchase through SwiftUI's `PurchaseAction` so StoreKit can
    /// present its sheet in the right scene.
    func purchase(using action: PurchaseAction) async {
        guard !flowState.isBusy else { return }        // one request at a time
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
            await refreshEntitlements()                 // renewal details for Parents
            flowState = verifiedLevel == .fullGame ? .purchased : .verificationFailed
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
            if product == nil { try? await fetchProduct() }    // for the renewal status; optional
            try await AppStore.sync()
            await refreshEntitlements()
            flowState = RestoreOutcome.resolve(verifiedActive: verifiedLevel == .fullGame, lapse: lapse)
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
        // Re-read everything rather than trusting this one transaction: an
        // update may be an old renewal, a refund, or a newer period.
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

    /// Plus is the configured auto-renewable subscription and nothing else.
    nonisolated static func isUnlock(_ transaction: StoreKit.Transaction, productID: String) -> Bool {
        transaction.productID == productID && transaction.productType == .autoRenewable
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
        apply(EntitlementResolver.resolve(
            evidence: [.verifiedActive(transactionID: transaction.id, expiresAt: transaction.expirationDate)],
            scanCompleted: true, cached: cache))
    }

    private func apply(_ decision: EntitlementDecision) {
        verifiedLevel = decision.level
        cache = decision.cache
        cacheStore.save(decision.cache)
        scheduleExpiryCheck()
    }

    /// Re-checks when the current period ends while the app is open (a
    /// renewal arrives through `updates`; an expiry has no event of its own).
    private func scheduleExpiryCheck() {
        expiryTask?.cancel()
        guard let end = cache?.expiresAt, end > Date() else { return }
        let delay = end.timeIntervalSinceNow + 2
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 86_400 * 40) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refreshEntitlements()
        }
    }
}
