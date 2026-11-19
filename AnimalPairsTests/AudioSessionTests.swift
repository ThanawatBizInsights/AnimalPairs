import AnimalPairsCore
import XCTest
@testable import AnimalPairs

/// The audio session is configured and activated once, off the main thread,
/// and never again for card flips, animal sounds or navigation.
@MainActor
final class AudioSessionTests: XCTestCase {
    /// Wraps the real background runner and records where and how often the
    /// activation work runs.
    private final class Recorder: @unchecked Sendable {
        var calls = 0
        var onMainThread = 0
    }

    private func recordingSession(_ recorder: Recorder) -> AudioSessionController {
        AudioSessionController(runner: { work, done in
            AudioSessionController.backgroundRunner({
                recorder.calls += 1
                if Thread.isMainThread { recorder.onMainThread += 1 }
                return work()
            }, done)
        })
    }

    func testActivationRunsOnceAndNeverOnTheMainThread() async throws {
        let recorder = Recorder()
        let model = AppModel(settings: SettingsStore(defaults: AppTestSupport.isolatedDefaults()),
                             configuration: AppConfiguration(fullUnlockProductID: AppConfiguration.defaultFullUnlockProductID,
                                                             privacyPolicyURL: nil, supportURL: nil),
                             history: SwiftDataCompletionStore.inMemory(),
                             snapshots: RoundSnapshotStore(directory: AppTestSupport.temporaryDirectory()),
                             playsOpeningVideo: false,
                             audioSession: recordingSession(recorder))
        model.start()                       // launch
        model.scenePhaseChanged(.active)    // first .active: coalesced with the launch request
        for _ in 0..<50 where model.audio.session.state != .active {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.audio.session.state, .active)
        XCTAssertEqual(recorder.calls, 1, "one activation at launch")

        // Navigation and a round with many flips: no further activation.
        try model.startNewGame(GameConfiguration(mode: .classic, boardSize: .six))
        let session = try XCTUnwrap(model.session)
        for tile in session.state.tiles.prefix(8) { session.tap(tile.id) }
        model.goHome()
        try model.startNewGame(GameConfiguration(mode: .classic, boardSize: .six))
        model.goHome()
        XCTAssertEqual(recorder.calls, 1, "flips, sounds and navigation never activate the session")

        // Background and back: exactly one reactivation.
        model.scenePhaseChanged(.background)
        model.scenePhaseChanged(.active)
        for _ in 0..<50 where model.audio.session.state != .active {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(recorder.calls, 2)
        XCTAssertEqual(recorder.onMainThread, 0, "setActive must not run on the main thread")
    }

    func testSoundsWaitForTheSessionInsteadOfActivatingItThemselves() {
        let session = AudioSessionController(runner: { _, _ in })   // activation never completes
        let audio = AudioManager(isEnabled: true, voiceEnabled: false, sessionController: session)
        audio.loadAnimalClips(for: ["momo"])
        XCTAssertNil(audio.playMatchClip(for: "momo"), "no sound before the session is active")
        audio.play(.cardFlip)
        XCTAssertEqual(session.activationCount, 1, "requests are coalesced into one activation")
        XCTAssertEqual(session.state, .activating)
    }
}
