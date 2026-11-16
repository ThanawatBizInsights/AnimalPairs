import Foundation

/// How one sound effect may be played.
public struct SoundRule: Equatable, Sendable {
    /// A repeat of the same effect sooner than this is dropped.
    public var minInterval: TimeInterval
    /// Higher wins when the voice limit is reached.
    public var priority: Int
    /// Approximate clip length, used to know when a voice is free again.
    public var duration: TimeInterval

    public init(minInterval: TimeInterval, priority: Int, duration: TimeInterval) {
        self.minInterval = minInterval
        self.priority = priority
        self.duration = duration
    }
}

public enum SoundDecision: Equatable, Sendable {
    /// Start the effect; first stop the listed effects to free a voice.
    case play(stopping: [String])
    /// The same effect is still sounding: restart it instead of layering a copy.
    case restart
    case skip(SoundSkipReason)
}

public enum SoundSkipReason: Equatable, Sendable {
    case tooSoon
    case tooManyVoices
}

/// Pure rules that keep rapid input from stacking into loud audio:
/// * the same effect never plays twice at once (it restarts instead);
/// * repeats faster than `minInterval` are dropped;
/// * at most `maxVoices` different effects overlap; a new effect only takes a
///   voice from a strictly lower-priority one.
public struct SoundPlaybackPolicy: Sendable {
    public let maxVoices: Int
    private var lastStart: [String: TimeInterval] = [:]
    private var voices: [String: (endsAt: TimeInterval, priority: Int)] = [:]

    public init(maxVoices: Int = 3) {
        self.maxVoices = max(1, maxVoices)
    }

    /// Effects currently considered audible at `now`.
    public func activeEffects(at now: TimeInterval) -> Set<String> {
        Set(voices.filter { $0.value.endsAt > now }.keys)
    }

    public mutating func request(_ effect: String, rule: SoundRule, at now: TimeInterval) -> SoundDecision {
        voices = voices.filter { $0.value.endsAt > now }

        if let last = lastStart[effect], now - last < rule.minInterval {
            return .skip(.tooSoon)
        }
        if voices[effect] != nil {
            register(effect, rule: rule, at: now)
            return .restart
        }
        var stopping: [String] = []
        if voices.count >= maxVoices {
            guard let victim = voices.min(by: { lhs, rhs in
                lhs.value.priority != rhs.value.priority
                    ? lhs.value.priority < rhs.value.priority
                    : lhs.value.endsAt < rhs.value.endsAt
            }), victim.value.priority < rule.priority else {
                return .skip(.tooManyVoices)
            }
            voices[victim.key] = nil
            stopping = [victim.key]
        }
        register(effect, rule: rule, at: now)
        return .play(stopping: stopping)
    }

    /// Forget everything (e.g. when sound effects are switched off).
    public mutating func reset() {
        lastStart = [:]
        voices = [:]
    }

    private mutating func register(_ effect: String, rule: SoundRule, at now: TimeInterval) {
        lastStart[effect] = now
        voices[effect] = (now + rule.duration, rule.priority)
    }
}
