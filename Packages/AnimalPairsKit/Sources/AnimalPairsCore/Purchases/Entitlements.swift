import Foundation

/// What StoreKit reported for the Animal Pairs Plus subscription, reduced to
/// facts the pure resolver can reason about.
public enum EntitlementEvidence: Equatable, Sendable {
    /// A cryptographically verified, non-revoked transaction. `expiresAt` is
    /// the subscription period's end (nil for a non-expiring product).
    case verifiedActive(transactionID: UInt64, expiresAt: Date? = nil)
    /// A verified transaction that has been refunded or revoked.
    case verifiedRevoked(transactionID: UInt64)
    /// StoreKit returned a transaction that failed verification.
    case unverified
}

/// The subscription's renewal state from StoreKit's subscription status
/// (verified), mirrored so the resolver stays pure.
public enum SubscriptionRenewalState: Equatable, Sendable {
    case subscribed
    /// Billing failed, but Apple's grace period still gives access.
    case inGracePeriod
    /// Billing failed and the grace period (if any) is over: no access.
    case inBillingRetry
    case expired
    case revoked
}

/// The last access granted from a verified transaction, kept so a verified
/// subscription remains usable before StoreKit has answered (e.g. an offline
/// launch) — but never past the end of the period it was verified for.
public struct CachedEntitlement: Codable, Equatable, Sendable {
    public let transactionID: UInt64
    public let verifiedAt: Date
    /// End of the verified subscription period (nil: does not expire).
    public let expiresAt: Date?

    public init(transactionID: UInt64, verifiedAt: Date, expiresAt: Date? = nil) {
        self.transactionID = transactionID
        self.verifiedAt = verifiedAt
        self.expiresAt = expiresAt
    }

    public func isValid(at now: Date) -> Bool { expiresAt.map { $0 > now } ?? true }
}

public struct EntitlementDecision: Equatable, Sendable {
    public let level: AccessLevel
    public let cache: CachedEntitlement?
}

/// Decides access without ever inventing a purchase:
/// * a verified, non-revoked transaction whose period has not ended → Plus
///   (cache refreshed with that period's end)
/// * StoreKit's status says subscribed or in the billing grace period → Plus
/// * a verified revocation (refund) and nothing active → free (cache cleared)
/// * StoreKit could not be scanned yet, or only unverified transactions →
///   keep a cached verified period while it lasts, else free
/// * a completed scan with nothing active → free (cache cleared): expired,
///   cancelled-and-lapsed or billing retry without grace
/// Being offline never removes access early (the cache covers the paid
/// period) and never extends it (the cache ends with the period).
public enum EntitlementResolver {
    public static func resolve(evidence: [EntitlementEvidence], renewalStates: [SubscriptionRenewalState] = [],
                               scanCompleted: Bool, cached: CachedEntitlement?,
                               now: Date = Date()) -> EntitlementDecision {
        var best: CachedEntitlement?
        for item in evidence {
            guard case .verifiedActive(let id, let expiresAt) = item, expiresAt.map({ $0 > now }) ?? true else { continue }
            let candidate = CachedEntitlement(transactionID: id, verifiedAt: now, expiresAt: expiresAt)
            if best == nil || (candidate.expiresAt ?? .distantFuture) > (best?.expiresAt ?? .distantFuture) {
                best = candidate
            }
        }
        if let best { return EntitlementDecision(level: .fullGame, cache: best) }
        if renewalStates.contains(where: { $0 == .subscribed || $0 == .inGracePeriod }) {
            return EntitlementDecision(level: .fullGame, cache: cached)
        }
        if evidence.contains(where: { if case .verifiedRevoked = $0 { return true } else { return false } }) {
            return EntitlementDecision(level: .starter, cache: nil)
        }
        if !scanCompleted || evidence.contains(.unverified) {
            guard let cached, cached.isValid(at: now) else { return EntitlementDecision(level: .starter, cache: nil) }
            return EntitlementDecision(level: .fullGame, cache: cached)
        }
        return EntitlementDecision(level: .starter, cache: nil)
    }
}

/// User-visible state of a purchase or restore attempt.
public enum PurchaseFlowState: Equatable, Sendable {
    case idle
    case loadingProducts
    case productUnavailable
    case purchasing
    case purchased
    /// Ask to Buy or another approval is outstanding.
    case pendingApproval
    case cancelled
    case verificationFailed
    case restoring
    case restoreFoundNothing
    case restored
    /// Apple's offer-code (gift code) sheet is open.
    case redeeming
    /// The sheet closed; waiting for StoreKit to deliver a verified transaction.
    case checkingRedemption
    /// A verified transaction for the unlock arrived after redeeming a code.
    case redeemed
    /// The sheet closed and no verified unlock arrived (cancelled, or Apple
    /// declined the code in its own sheet).
    case redeemFoundNothing
    /// The App Store could not be reached.
    case networkUnavailable
    case failed(String)

    /// True while a purchase, restore or redemption is under way.
    public var isBusy: Bool {
        switch self {
        case .purchasing, .restoring, .redeeming, .checkingRedemption: true
        default: false
        }
    }
}

/// How a gift-code redemption ended. Only a *verified* unlock that was not
/// there before the sheet opened counts as a redemption; closing the sheet on
/// its own never unlocks anything.
public enum RedemptionOutcome {
    public static func resolve(unlockedBefore: Bool, verifiedUnlockedNow: Bool,
                               sheetFailedForNetwork: Bool) -> PurchaseFlowState {
        if verifiedUnlockedNow { return unlockedBefore ? .restored : .redeemed }
        return sheetFailedForNetwork ? .networkUnavailable : .redeemFoundNothing
    }
}
