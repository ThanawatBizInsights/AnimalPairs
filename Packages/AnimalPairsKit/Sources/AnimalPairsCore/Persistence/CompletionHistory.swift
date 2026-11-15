import Foundation

/// One completed round as kept in local history. Contains no personal data.
public struct CompletionRecord: Codable, Hashable, Sendable, Identifiable {
    public let roundID: UUID
    public let mode: GameMode
    public let boardSize: BoardSize
    public let attempts: Int
    public let hintsUsed: Int
    public let pairCount: Int
    public let startedAt: Date
    public let completedAt: Date

    public var id: UUID { roundID }

    public init(summary: RoundSummary) {
        roundID = summary.roundID
        mode = summary.configuration.mode
        boardSize = summary.configuration.boardSize
        attempts = summary.attempts
        hintsUsed = summary.hintsUsed
        pairCount = summary.pairCount
        startedAt = summary.startedAt
        completedAt = summary.completedAt
    }
}

/// Lifetime aggregates. They survive trimming of the recent-records list.
public struct ProgressTotals: Codable, Equatable, Sendable {
    public var roundsCompleted: Int = 0
    public var pairsMatched: Int = 0
    public var attempts: Int = 0
    public var hintsUsed: Int = 0
    /// Keyed by `BoardSize.rawValue`.
    public var roundsByBoard: [Int: Int] = [:]
    /// Keyed by `GameMode.rawValue`.
    public var roundsByMode: [String: Int] = [:]
    public var lastCompletedAt: Date?

    public init() {}

    public mutating func add(_ record: CompletionRecord) {
        roundsCompleted += 1
        pairsMatched += record.pairCount
        attempts += record.attempts
        hintsUsed += record.hintsUsed
        roundsByBoard[record.boardSize.rawValue, default: 0] += 1
        roundsByMode[record.mode.rawValue, default: 0] += 1
        if lastCompletedAt.map({ record.completedAt > $0 }) ?? true { lastCompletedAt = record.completedAt }
    }
}

public enum HistoryPolicy {
    /// Number of individual results kept; older ones only live on in totals.
    public static let maxRecentRecords = 100
    /// Round IDs remembered for de-duplication beyond the recent list.
    public static let maxRememberedRoundIDs = 5_000
}

/// Persistence-agnostic contract implemented by SwiftData in the app and by an
/// in-memory store in tests.
public protocol CompletionHistoryStore: AnyObject {
    /// Records a completed round once. Returns false if the round ID is known.
    @discardableResult
    func record(_ summary: RoundSummary) throws -> Bool
    func recentRecords() throws -> [CompletionRecord]
    func totals() throws -> ProgressTotals
    /// Clears history and totals. Purchases are not stored here and are kept.
    func resetProgress() throws
}

/// Pure ledger logic shared by every store implementation.
public struct CompletionLedger: Codable, Equatable, Sendable {
    public private(set) var records: [CompletionRecord] = []
    public private(set) var totals = ProgressTotals()
    /// Ordered oldest → newest, bounded.
    public private(set) var rememberedRoundIDs: [UUID] = []

    public init() {}

    public func contains(_ roundID: UUID) -> Bool {
        records.contains { $0.roundID == roundID } || rememberedRoundIDs.contains(roundID)
    }

    /// Returns the record IDs that were trimmed, or nil if the round was a duplicate.
    @discardableResult
    public mutating func record(_ summary: RoundSummary) -> [UUID]? {
        guard !contains(summary.roundID) else { return nil }
        let record = CompletionRecord(summary: summary)
        records.append(record)
        totals.add(record)
        rememberedRoundIDs.append(record.roundID)
        if rememberedRoundIDs.count > HistoryPolicy.maxRememberedRoundIDs {
            rememberedRoundIDs.removeFirst(rememberedRoundIDs.count - HistoryPolicy.maxRememberedRoundIDs)
        }
        records.sort { $0.completedAt > $1.completedAt }
        guard records.count > HistoryPolicy.maxRecentRecords else { return [] }
        let trimmed = records[HistoryPolicy.maxRecentRecords...].map(\.roundID)
        records.removeLast(records.count - HistoryPolicy.maxRecentRecords)
        return Array(trimmed)
    }

    public mutating func reset() {
        self = CompletionLedger()
    }
}

/// Reference implementation (tests, previews, and a fallback when the
/// on-disk database cannot be opened).
public final class InMemoryCompletionHistory: CompletionHistoryStore {
    public private(set) var ledger = CompletionLedger()
    public init() {}

    @discardableResult
    public func record(_ summary: RoundSummary) throws -> Bool { ledger.record(summary) != nil }
    public func recentRecords() throws -> [CompletionRecord] { ledger.records }
    public func totals() throws -> ProgressTotals { ledger.totals }
    public func resetProgress() throws { ledger.reset() }
}
