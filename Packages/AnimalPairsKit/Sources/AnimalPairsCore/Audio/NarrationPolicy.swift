import Foundation

/// The spoken lines the game can use.
public enum NarrationCue: String, CaseIterable, Sendable {
    case findPair = "find_pair"
    case greatMatch = "great_match"
    case tryAgain = "try_again_voice"
    case allDone = "all_done"
}

/// Keeps narration occasional, never naggy:
/// * at most one line per `minimumGap` seconds (the end-of-board line only
///   needs `completionGap`);
/// * "find a pair" only when a round starts after a long quiet spell;
/// * praise on every `matchesPerPraise`-th match, not every match;
/// * encouragement only after `missesBeforeEncouragement` misses in a row.
public struct NarrationPolicy: Sendable {
    public var minimumGap: TimeInterval = 20
    public var completionGap: TimeInterval = 3
    public var findPairQuietPeriod: TimeInterval = 120
    public var matchesPerPraise = 3
    public var missesBeforeEncouragement = 3

    private var lastSpoken: TimeInterval?
    private var matchesSincePraise = 0
    private var consecutiveMisses = 0

    public init() {}

    private func quiet(for gap: TimeInterval, at now: TimeInterval) -> Bool {
        guard let lastSpoken else { return true }
        return now - lastSpoken >= gap
    }

    private mutating func speak(_ cue: NarrationCue, at now: TimeInterval) -> NarrationCue {
        lastSpoken = now
        return cue
    }

    public mutating func roundStarted(at now: TimeInterval) -> NarrationCue? {
        matchesSincePraise = 0
        consecutiveMisses = 0
        return quiet(for: findPairQuietPeriod, at: now) ? speak(.findPair, at: now) : nil
    }

    /// A non-final pair was matched.
    public mutating func matched(at now: TimeInterval) -> NarrationCue? {
        consecutiveMisses = 0
        matchesSincePraise += 1
        guard matchesSincePraise >= matchesPerPraise, quiet(for: minimumGap, at: now) else { return nil }
        matchesSincePraise = 0
        return speak(.greatMatch, at: now)
    }

    public mutating func missed(at now: TimeInterval) -> NarrationCue? {
        consecutiveMisses += 1
        guard consecutiveMisses >= missesBeforeEncouragement, quiet(for: minimumGap, at: now) else { return nil }
        consecutiveMisses = 0
        return speak(.tryAgain, at: now)
    }

    public mutating func completed(at now: TimeInterval) -> NarrationCue? {
        consecutiveMisses = 0
        matchesSincePraise = 0
        return quiet(for: completionGap, at: now) ? speak(.allDone, at: now) : nil
    }
}
