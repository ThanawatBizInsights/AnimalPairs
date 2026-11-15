import Foundation

/// An adult-oriented check: a multiplication question presented in words
/// (young children who cannot yet read cannot follow it). This is a speed
/// bump, not age verification or legal consent.
public struct ParentalGateChallenge: Equatable, Sendable {
    public let lhs: Int
    public let rhs: Int
    public var answer: Int { lhs * rhs }

    public init(lhs: Int, rhs: Int) {
        self.lhs = lhs
        self.rhs = rhs
    }

    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> ParentalGateChallenge {
        ParentalGateChallenge(lhs: Int.random(in: 3...9, using: &generator), rhs: Int.random(in: 6...9, using: &generator))
    }

    /// Accepts ASCII and Thai digits, ignoring surrounding whitespace.
    public func accepts(_ input: String) -> Bool {
        guard let value = Self.parse(input) else { return false }
        return value == answer
    }

    public static func parse(_ input: String) -> Int? {
        let thaiDigits: [Character: Character] = ["๐": "0", "๑": "1", "๒": "2", "๓": "3", "๔": "4",
                                                  "๕": "5", "๖": "6", "๗": "7", "๘": "8", "๙": "9"]
        let normalized = String(input.trimmingCharacters(in: .whitespacesAndNewlines).map { thaiDigits[$0] ?? $0 })
        guard !normalized.isEmpty, normalized.count <= 3, normalized.allSatisfy(\.isASCII) else { return nil }
        return Int(normalized)
    }
}

public enum ParentalGateResult: Equatable, Sendable {
    case granted
    case incorrect(attemptsRemaining: Int)
    /// Too many wrong answers; a fresh question is shown.
    case newChallenge
}

public struct ParentalGate: Sendable {
    public static let attemptsPerChallenge = 3
    public private(set) var challenge: ParentalGateChallenge
    public private(set) var failedAttempts = 0

    public init(challenge: ParentalGateChallenge) {
        self.challenge = challenge
    }

    public mutating func submit<G: RandomNumberGenerator>(_ input: String, using generator: inout G) -> ParentalGateResult {
        if challenge.accepts(input) {
            failedAttempts = 0
            return .granted
        }
        failedAttempts += 1
        if failedAttempts >= Self.attemptsPerChallenge {
            refresh(using: &generator)
            return .newChallenge
        }
        return .incorrect(attemptsRemaining: Self.attemptsPerChallenge - failedAttempts)
    }

    public mutating func refresh<G: RandomNumberGenerator>(using generator: inout G) {
        var next = ParentalGateChallenge.random(using: &generator)
        var guardCount = 0
        while next == challenge && guardCount < 8 {
            next = ParentalGateChallenge.random(using: &generator)
            guardCount += 1
        }
        challenge = next
        failedAttempts = 0
    }
}

/// Short-lived access to the Parents area. Expires on timeout, when the
/// Parents area is left, or when the app goes to the background.
public struct ParentAccessSession: Equatable, Sendable {
    public static let defaultLifetime: TimeInterval = 5 * 60

    public private(set) var grantedAt: Date?
    public let lifetime: TimeInterval

    public init(lifetime: TimeInterval = ParentAccessSession.defaultLifetime) {
        self.lifetime = lifetime
    }

    public mutating func grant(now: Date = Date()) { grantedAt = now }
    public mutating func revoke() { grantedAt = nil }

    public func isActive(now: Date = Date()) -> Bool {
        guard let grantedAt else { return false }
        let age = now.timeIntervalSince(grantedAt)
        return age >= 0 && age < lifetime
    }
}
