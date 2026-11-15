import XCTest
@testable import AnimalPairsCore

final class TaskSchedulerTests: XCTestCase {
    @MainActor private final class Flags {
        var fired: [String] = []
    }

    func testFiresAfterDelayAndCancelledWorkNeverRuns() async throws {
        let flags = await MainActor.run { Flags() }
        let cancelled: ScheduledWork = await MainActor.run {
            let scheduler = TaskRoundScheduler()
            _ = scheduler.schedule(after: 0.05) { flags.fired.append("kept") }
            return scheduler.schedule(after: 0.05) { flags.fired.append("cancelled") }
        }
        cancelled.cancel()
        try await Task.sleep(nanoseconds: 400_000_000)
        let fired = await MainActor.run { flags.fired }
        XCTAssertEqual(fired, ["kept"])
    }

    func testRealTimeMismatchFlowCoversCards() async throws {
        let (controller, a, b) = try await MainActor.run { () throws -> (RoundController, TileID, TileID) in
            let controller = RoundController(state: try Fixtures.round(), scheduler: TaskRoundScheduler(),
                                             timing: RoundTiming(matchDelay: 0.02, mismatchDelay: 0.05, hintDuration: 0.05))
            let (a, b) = Fixtures.mismatchedPair(in: controller.state)
            controller.tap(a)
            controller.tap(b)
            return (controller, a, b)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let faces = await MainActor.run { [controller.state.tile(a)?.face, controller.state.tile(b)?.face] }
        XCTAssertEqual(faces, [.covered, .covered])
    }
}
