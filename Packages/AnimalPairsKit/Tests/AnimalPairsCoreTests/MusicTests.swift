@testable import AnimalPairsCore
import XCTest

final class MusicPolicyTests: XCTestCase {
    func testHomeSetupAndGameplayShareOneContinuousTrack() {
        XCTAssertEqual(MusicPolicy.track(for: .menus), .playground)
        XCTAssertEqual(MusicPolicy.track(for: .game), MusicPolicy.track(for: .menus),
                       "the same loop, so Home → board → game never restarts it")
        XCTAssertEqual(MusicPolicy.track(for: .results), .celebration)
        XCTAssertEqual(MusicPolicy.track(for: .parents), .meadow)
        XCTAssertNil(MusicPolicy.track(for: .silent))
        XCTAssertEqual(MusicPolicy.startDelay(for: .game), 0, "gameplay music never waits")
        XCTAssertGreaterThan(MusicPolicy.startDelay(for: .results), 0, "the results jingle plays first")
    }

    func testMusicIsHeardOnlyWhenEverythingAllowsIt() {
        XCTAssertTrue(MusicPolicy.isAudible(enabled: true, appActive: true, interrupted: false,
                                            otherAudioPlaying: false, heldAfterRouteLoss: false))
        let blockers: [(Bool, Bool, Bool, Bool, Bool)] = [
            (false, true, false, false, false), (true, false, false, false, false),
            (true, true, true, false, false), (true, true, false, true, false), (true, true, false, false, true),
        ]
        for b in blockers {
            XCTAssertFalse(MusicPolicy.isAudible(enabled: b.0, appActive: b.1, interrupted: b.2,
                                                 otherAudioPlaying: b.3, heldAfterRouteLoss: b.4), "\(b)")
        }
    }
}
