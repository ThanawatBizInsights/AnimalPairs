import Foundation

/// Handle to a delayed piece of work.
public protocol ScheduledWork: AnyObject {
    func cancel()
}

/// Abstraction over delayed execution so timing is testable without sleeping.
@MainActor
public protocol RoundScheduler: AnyObject {
    func schedule(after seconds: Double, _ work: @escaping @MainActor () -> Void) -> ScheduledWork
}

/// Production scheduler backed by cancellable Swift concurrency tasks.
@MainActor
public final class TaskRoundScheduler: RoundScheduler {
    public init() {}

    public func schedule(after seconds: Double, _ work: @escaping @MainActor () -> Void) -> ScheduledWork {
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            work()
        }
        return TaskWork(task: task)
    }

    private final class TaskWork: ScheduledWork {
        let task: Task<Void, Never>
        init(task: Task<Void, Never>) { self.task = task }
        func cancel() { task.cancel() }
    }
}

public struct RoundTiming: Equatable, Sendable {
    /// How long a matching pair is shown before it is committed.
    public var matchDelay: Double
    /// How long a mismatched pair stays visible before both turn face down.
    public var mismatchDelay: Double
    /// How long hint outlines stay visible.
    public var hintDuration: Double

    public init(matchDelay: Double = 0.6, mismatchDelay: Double = 1.2, hintDuration: Double = 1.8) {
        self.matchDelay = matchDelay
        self.mismatchDelay = mismatchDelay
        self.hintDuration = hintDuration
    }

    public static let standard = RoundTiming()
}

public enum RoundEvent: Equatable, Sendable {
    case revealed(TileID)
    case matched(PairKey)
    case mismatchCovered
    case hintShown(HintTarget)
    case tapIgnored(TapIgnoredReason)
    /// Emitted exactly once per round.
    case completed(RoundSummary)
}

/// Type-erased random generator so the controller can hold any generator.
public struct AnyRandomGenerator: RandomNumberGenerator {
    private var nextValue: () -> UInt64
    public init<G: RandomNumberGenerator>(_ base: G) {
        var base = base
        nextValue = { base.next() }
    }
    public mutating func next() -> UInt64 { nextValue() }
}

/// Drives one round in real time: serialises input, schedules resolutions,
/// guards every delayed callback with the round ID, a generation counter and
/// the resolution token, and cancels obsolete work on pause, restart or exit.
@MainActor
public final class RoundController {
    public private(set) var state: RoundState
    /// Cards currently outlined by a hint (transient, never persisted).
    public private(set) var highlightedTiles: Set<TileID> = []

    public var onChange: (() -> Void)?
    public var onEvent: ((RoundEvent) -> Void)?

    private let scheduler: RoundScheduler
    private let timing: RoundTiming
    private let now: () -> Date
    private var generator: AnyRandomGenerator

    private var generation: UInt64 = 0
    private var resolutionWork: ScheduledWork?
    private var hintWork: ScheduledWork?
    private var hintToken: UInt64 = 0
    private var isTornDown = false
    private var didReportCompletion = false

    public init(state: RoundState,
                scheduler: RoundScheduler,
                timing: RoundTiming = .standard,
                generator: AnyRandomGenerator = AnyRandomGenerator(SystemRandomNumberGenerator()),
                now: @escaping () -> Date = Date.init) {
        self.state = state
        self.scheduler = scheduler
        self.timing = timing
        self.generator = generator
        self.now = now
        self.didReportCompletion = state.isCompleted
    }

    public var isActive: Bool { !isTornDown }

    // MARK: Input

    public func tap(_ id: TileID) {
        guard !isTornDown else { return }
        let outcome = state.tap(id)
        switch outcome {
        case .ignored(let reason):
            onEvent?(.tapIgnored(reason))
            return
        case .revealedFirst(let tileID):
            clearHint()
            onEvent?(.revealed(tileID))
        case .revealedSecond(let resolution):
            clearHint()
            onEvent?(.revealed(resolution.second))
            scheduleResolution(resolution)
        }
        onChange?()
    }

    public func requestHint() {
        guard !isTornDown else { return }
        guard let target = state.useHint(using: &generator) else { return }
        switch target {
        case .pair(let a, let b): highlightedTiles = [a, b]
        case .partner(let id): highlightedTiles = [id]
        }
        hintWork?.cancel()
        hintToken += 1
        let token = hintToken, gen = generation, roundID = state.roundID
        hintWork = scheduler.schedule(after: timing.hintDuration) { [weak self] in
            guard let self, !self.isTornDown, gen == self.generation, roundID == self.state.roundID,
                  token == self.hintToken else { return }
            self.highlightedTiles = []
            self.onChange?()
        }
        onEvent?(.hintShown(target))
        onChange?()
    }

    // MARK: Lifecycle

    /// Pauses and normalizes: a pending match is committed once, a pending
    /// mismatch is covered, a single open card stays open.
    public func pause() {
        guard !isTornDown else { return }
        invalidateScheduledWork()
        clearHint()
        let outcome = state.pause(now: now())
        if let outcome { handle(outcome) }
        onChange?()
    }

    public func resume() {
        guard !isTornDown else { return }
        state.resume()
        onChange?()
    }

    /// Replaces the round (restart). Old callbacks can no longer affect it.
    public func replaceRound(with newState: RoundState) {
        invalidateScheduledWork()
        clearHint()
        state = newState
        isTornDown = false
        didReportCompletion = newState.isCompleted
        onChange?()
    }

    /// Stops all work, e.g. when leaving the board.
    public func tearDown() {
        invalidateScheduledWork()
        highlightedTiles = []
        isTornDown = true
    }

    /// A normalized copy suitable for saving; the live round is unchanged.
    public func normalizedState() -> RoundState {
        var copy = state
        copy.normalize(now: now())
        return copy
    }

    // MARK: Private

    private func invalidateScheduledWork() {
        generation &+= 1
        resolutionWork?.cancel()
        resolutionWork = nil
        hintWork?.cancel()
        hintWork = nil
    }

    private func clearHint() {
        hintWork?.cancel()
        hintWork = nil
        hintToken += 1
        highlightedTiles = []
    }

    private func scheduleResolution(_ resolution: Resolution) {
        resolutionWork?.cancel()
        let gen = generation, roundID = state.roundID, token = resolution.token
        let delay = resolution.isMatch ? timing.matchDelay : timing.mismatchDelay
        resolutionWork = scheduler.schedule(after: delay) { [weak self] in
            self?.completeResolution(generation: gen, roundID: roundID, token: token)
        }
    }

    private func completeResolution(generation gen: UInt64, roundID: UUID, token: UInt64) {
        guard !isTornDown, gen == generation, roundID == state.roundID else { return }
        let outcome = state.finishResolution(token: token, now: now())
        guard outcome != .ignoredStale else { return }
        resolutionWork = nil
        handle(outcome)
        onChange?()
    }

    private func handle(_ outcome: ResolutionOutcome) {
        switch outcome {
        case .ignoredStale:
            break
        case .coveredMismatch:
            onEvent?(.mismatchCovered)
        case .matched(let key, let completed):
            onEvent?(.matched(key))
            if completed { reportCompletionIfNeeded() }
        }
    }

    private func reportCompletionIfNeeded() {
        guard !didReportCompletion, let summary = state.summary else { return }
        didReportCompletion = true
        onEvent?(.completed(summary))
    }
}
