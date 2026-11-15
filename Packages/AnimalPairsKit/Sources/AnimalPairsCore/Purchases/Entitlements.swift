import Foundation

/// What StoreKit reported for the full-unlock product, reduced to facts the
/// pure resolver can reason about.
public enum EntitlementEvidence: Equatable, Sendable {
    /// A cryptographically verified, non-revoked transaction.
    case verifiedActive(transactionID: UInt64)
    /// A verified transaction that has been refunded or revoked.
    case verifiedRevoked(transactionID: UInt64)
    /// StoreKit returned a transaction that failed verification.
    case unverified
}

/// The last access granted from a verified transaction, kept so a previously
/// verified unlock remains usable before StoreKit has finished answering.
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
/// * any verified active transaction → full game (cache refreshed)
/// * a verified revocation (and nothing active) → starter (cache cleared)
/// * only unverified transactions → keep a previously verified cache, else starter
/// * a completed scan with no transactions → starter (cache cleared)
/// * StoreKit could not be scanned yet → keep the cache
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
            return EntitlementDecision(level: cached == nil ? .starter : .fullGame, cache: cached)
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
    case failed(String)
}
