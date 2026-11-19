import Foundation

/// What StoreKit reported for the one-time "Full Game Unlock" (a
/// non-consumable), reduced to facts the pure resolver can reason about.
public enum EntitlementEvidence: Equatable, Sendable {
    /// A cryptographically verified, non-revoked transaction for the product.
    case verifiedActive(transactionID: UInt64)
    /// A verified transaction that Apple has refunded or revoked.
    case verifiedRevoked(transactionID: UInt64)
    /// StoreKit returned a transaction that failed verification.
    case unverified
}

/// The ID of the last *verified* Full Game Unlock transaction. It lets a
/// launch before StoreKit has answered (offline, slow start) keep the
/// unlock. It is not proof of purchase on its own: a completed StoreKit scan
/// without the entitlement (a refund) clears it, and it is only written from
/// a verified transaction.
public struct CachedEntitlement: Codable, Equatable, Sendable {
    public let transactionID: UInt64
    public let verifiedAt: Date

    public init(transactionID: UInt64, verifiedAt: Date) {
        self.transactionID = transactionID
        self.verifiedAt = verifiedAt
    }
}

public struct EntitlementDecision: Equatable, Sendable {
    public let level: AccessLevel
    public let cache: CachedEntitlement?
}

/// Decides access without ever inventing a purchase:
/// * a verified, non-revoked transaction → Full Game (cache refreshed)
/// * a verified revocation (refund) and nothing active → free (cache cleared)
/// * StoreKit could not be scanned yet, or returned only unverified
///   transactions → keep a previously verified unlock if cached, else free
/// * a completed scan with nothing → free (cache cleared)
/// The purchase never expires, so there is no end date to check.
public enum EntitlementResolver {
    public static func resolve(evidence: [EntitlementEvidence], scanCompleted: Bool,
                               cached: CachedEntitlement?, now: Date = Date()) -> EntitlementDecision {
        for item in evidence {
            if case .verifiedActive(let id) = item {
                return EntitlementDecision(level: .fullGame, cache: CachedEntitlement(transactionID: id, verifiedAt: now))
            }
        }
        if evidence.contains(where: { if case .verifiedRevoked = $0 { return true } else { return false } }) {
            return EntitlementDecision(level: .starter, cache: nil)
        }
        if !scanCompleted || evidence.contains(.unverified) {
            guard let cached else { return EntitlementDecision(level: .starter, cache: nil) }
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
    /// Restore finished and this Apple Account has no Full Game Unlock (or
    /// it was bought with a different Apple Account).
    case restoreFoundNothing
    /// Restore finished: the purchase exists but Apple refunded or revoked it.
    case restoreFoundRefunded
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

/// What a parent's Restore Purchases ended with, once `AppStore.sync()`
/// succeeded and verified entitlements were read again.
public enum RestoreOutcome {
    /// - Parameter refunded: the newest verified transaction for the product
    ///   has been refunded or revoked by Apple.
    public static func resolve(owned: Bool, refunded: Bool) -> PurchaseFlowState {
        if owned { return .restored }
        return refunded ? .restoreFoundRefunded : .restoreFoundNothing
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
