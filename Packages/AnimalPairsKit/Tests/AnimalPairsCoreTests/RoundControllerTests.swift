import XCTest
@testable import AnimalPairsCore

/// Test methods are nonisolated and hop to the main actor explicitly, because
/// swift-corelibs-xctest (Linux) cannot invoke `@MainActor` test methods.
final class RoundControllerTests: XCTestCase {
    @MainActor
    private func makeController(_ config: GameConfiguration = GameConfiguration(mode: .classic, boardSize: .six))
        throws -> (RoundController, ManualScheduler, Recorder) {
        let scheduler = ManualScheduler()
        let controller = RoundController(state: try Fixtures.round(config), scheduler: scheduler,
                                         generator: AnyRandomGenerator(SeededGenerator(seed: 9)))
        let recorder = Recorder()
        controller.onEvent = { recorder.events.append($0) }
        return (controller, scheduler, recorder)
    }

    final class Recorder {
        var events: [RoundEvent] = []
        var completions: [RoundSummary] {
            events.compactMap { if case .completed(let s) = $0 { return s } else { return nil } }
        }
    }

    func testMismatchStaysVisibleFor1Point2SecondsThenCoversTogether() async throws {
        try await MainActor.run {
            let (controller, scheduler, _) = try makeController()
            let (a, b) = Fixtures.mismatchedPair(in: controller.state)
            controller.tap(a)
            controller.tap(b)
            scheduler.advance(by: 1.19)
            XCTAssertEqual(controller.state.tile(a)?.face, .revealed)
            XCTAssertEqual(controller.state.tile(b)?.face, .revealed)
            scheduler.advance(by: 0.02)
            XCTAssertEqual(controller.state.tile(a)?.face, .covered)
            XCTAssertEqual(controller.state.tile(b)?.face, .covered)
            XCTAssertEqual(controller.state.phase, .ready)
        }
    }

    func testRapidTapsNeverRevealAThirdCard() async throws {
        try await MainActor.run {
            let (controller, scheduler, _) = try makeController(GameConfiguration(mode: .classic, boardSize: .twenty))
            let ids = controller.state.tiles.map(\.id)
            // A burst of taps across the whole board, including repeats.
            for id in ids + ids.reversed() + ids { controller.tap(id) }
            XCTAssertEqual(controller.state.tiles.filter { $0.face == .revealed }.count, 2)
            XCTAssertEqual(controller.state.attempts, 1)
            XCTAssertEqual(scheduler.pending.count, 1, "exactly one resolution scheduled")
            scheduler.advance(by: 2)
            XCTAssertLessThanOrEqual(controller.state.tiles.filter { $0.face == .revealed }.count, 0)
        }
    }

    func testStaleCallbackCannotChangeARestartedRound() async throws {
        try await MainActor.run {
            let (controller, scheduler, _) = try makeController()
            let (a, b) = Fixtures.matchingPair(in: controller.state)
            controller.tap(a)
            controller.tap(b)
            let newRound = try Fixtures.round(seed: 99)
            controller.replaceRound(with: newRound)
            // Even if the cancelled callback still runs, it must not touch the new round.
            scheduler.fireEverythingIncludingCancelled()
            XCTAssertEqual(controller.state, newRound)
            XCTAssertEqual(controller.state.matchedPairs, 0)
        }
    }

    func testStaleCallbackAfterPauseDoesNotCommitTwice() async throws {
        try await MainActor.run {
            let (controller, scheduler, recorder) = try makeController()
            let (a, b) = Fixtures.matchingPair(in: controller.state)
            controller.tap(a)
            controller.tap(b)
            controller.pause()
            XCTAssertEqual(controller.state.matchedPairs, 1)
            scheduler.fireEverythingIncludingCancelled()
            controller.resume()
            XCTAssertEqual(controller.state.matchedPairs, 1)
            XCTAssertEqual(recorder.events.filter { if case .matched = $0 { return true } else { return false } }.count, 1)
        }
    }

    func testTearDownStopsAllWork() async throws {
        try await MainActor.run {
            let (controller, scheduler, _) = try makeController()
            let (a, b) = Fixtures.mismatchedPair(in: controller.state)
            controller.tap(a)
            controller.tap(b)
            controller.tearDown()
            XCTAssertTrue(scheduler.pending.isEmpty)
            scheduler.fireEverythingIncludingCancelled()
            XCTAssertEqual(controller.state.tile(a)?.face, .revealed, "no mutation after teardown")
            controller.tap(controller.state.tiles.last!.id)
            XCTAssertEqual(controller.state.attempts, 1)
        }
    }

    func testCompletionReportedExactlyOnce() async throws {
        try await MainActor.run {
            let (controller, scheduler, recorder) = try makeController()
            while !controller.state.isCompleted {
                let (a, b) = Fixtures.matchingPair(in: controller.state)
                controller.tap(a)
                controller.tap(b)
                scheduler.advance(by: 1)
            }
            controller.pause()
            controller.resume()
            scheduler.fireEverythingIncludingCancelled()
            XCTAssertEqual(recorder.completions.count, 1)
            XCTAssertEqual(recorder.completions.first?.attempts, 3)
        }
    }

    func testCompletionDuringPauseNormalizationIsReportedOnce() async throws {
        try await MainActor.run {
            let (controller, scheduler, recorder) = try makeController()
            for _ in 0..<2 {
                let (a, b) = Fixtures.matchingPair(in: controller.state)
                controller.tap(a)
                controller.tap(b)
                scheduler.advance(by: 1)
            }
            let (a, b) = Fixtures.matchingPair(in: controller.state)
            controller.tap(a)
            controller.tap(b)
            controller.pause() // commits the final pair
            XCTAssertTrue(controller.state.isCompleted)
            scheduler.fireEverythingIncludingCancelled()
            XCTAssertEqual(recorder.completions.count, 1)
        }
    }

    func testHintHighlightsClearAndDoNotCountAsAttempts() async throws {
        try await MainActor.run {
            let (controller, scheduler, _) = try makeController()
            controller.requestHint()
            XCTAssertEqual(controller.highlightedTiles.count, 2)
            XCTAssertEqual(controller.state.hintsUsed, 1)
            XCTAssertEqual(controller.state.attempts, 0)
            scheduler.advance(by: RoundTiming.standard.hintDuration + 0.01)
            XCTAssertTrue(controller.highlightedTiles.isEmpty)

            controller.requestHint()
            controller.tap(controller.state.tiles[0].id) // tapping clears the outline
            XCTAssertTrue(controller.highlightedTiles.isEmpty)
            controller.requestHint()
            XCTAssertEqual(controller.highlightedTiles.count, 1, "partner of the open card")
            XCTAssertEqual(controller.state.hintsUsed, 3)
        }
    }

    func testOldHintTimerDoesNotClearNewerHint() async throws {
        try await MainActor.run {
            let (controller, scheduler, _) = try makeController()
            controller.requestHint()
            scheduler.advance(by: 1.0)
            controller.requestHint()
            scheduler.advance(by: 1.0) // first hint's timer would have fired here
            XCTAssertFalse(controller.highlightedTiles.isEmpty)
        }
    }

    func testNormalizedStateDoesNotMutateLiveRound() async throws {
        try await MainActor.run {
            let (controller, _, _) = try makeController()
            let (a, b) = Fixtures.mismatchedPair(in: controller.state)
            controller.tap(a)
            controller.tap(b)
            let normalized = controller.normalizedState()
            XCTAssertEqual(normalized.phase, .ready)
            XCTAssertNotNil(controller.state.pendingResolution)
        }
    }
}
