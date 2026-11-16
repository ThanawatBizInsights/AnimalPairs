@testable import AnimalPairsCore
import XCTest

final class MusicPolicyTests: XCTestCase {
    func testEachSceneHasItsTrackAndOnlyOne() {
        XCTAssertEqual(MusicPolicy.track(for: .menus), .playground)
        XCTAssertEqual(MusicPolicy.track(for: .game), .focus)
        XCTAssertEqual(MusicPolicy.track(for: .results), .celebration)
        XCTAssertEqual(MusicPolicy.track(for: .parents), .meadow)
        XCTAssertNil(MusicPolicy.track(for: .silent))
        XCTAssertEqual(Set([MusicScene.menus, .game, .results, .parents].compactMap(MusicPolicy.track)),
                       Set(AnimalPairsMusicTrack.allCases), "all four loops are used")
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

final class VolumeRampTests: XCTestCase {
    func testRampIsSmoothAndEndsExactly() {
        let ramp = VolumeRamp(from: 0, to: 1, start: 10, duration: 2)
        XCTAssertEqual(ramp.value(at: 9), 0)
        XCTAssertEqual(ramp.value(at: 10), 0)
        XCTAssertEqual(ramp.value(at: 11), 0.5, accuracy: 0.001)
        XCTAssertEqual(ramp.value(at: 12), 1)
        XCTAssertTrue(ramp.isFinished(at: 12))
        var previous: Float = 0
        for i in 0...200 {
            let v = ramp.value(at: 10 + Double(i) / 100)
            XCTAssertGreaterThanOrEqual(v, previous)
            XCTAssertLessThan(v - previous, 0.02, "no jumps")
            previous = v
        }
    }

    func testRetargetingMidFadeContinuesFromTheCurrentLevel() {
        let fadeIn = VolumeRamp(from: 0, to: 1, start: 0, duration: 2)
        let fadeOut = fadeIn.retargeted(to: 0, at: 1, duration: 1)
        XCTAssertEqual(fadeOut.value(at: 1), fadeIn.value(at: 1), accuracy: 0.0001)
        XCTAssertEqual(fadeOut.value(at: 2), 0)
        XCTAssertEqual(VolumeRamp.steady(0.3).value(at: 99), 0.3)
    }
}

final class MusicDuckTests: XCTestCase {
    func testDucksDuringAClipAndRestoresSmoothly() {
        var duck = MusicDuck(depth: 0.35, attack: 0.15, release: 0.8)
        XCTAssertEqual(duck.level(at: 5), 1)
        duck.duck(at: 10, until: 12)
        XCTAssertEqual(duck.level(at: 10), 1)
        XCTAssertEqual(duck.level(at: 10.15), 0.35, accuracy: 0.001)
        XCTAssertEqual(duck.level(at: 11.5), 0.35, accuracy: 0.001)
        XCTAssertEqual(duck.level(at: 12.4), 0.675, accuracy: 0.01)
        XCTAssertEqual(duck.level(at: 12.8), 1, accuracy: 0.001)
        XCTAssertFalse(duck.isActive(at: 13))
    }

    func testOverlappingClipsExtendTheDipInsteadOfStacking() {
        var duck = MusicDuck(depth: 0.35, attack: 0.15, release: 0.8)
        duck.duck(at: 10, until: 11)
        duck.duck(at: 10.5, until: 12)
        XCTAssertEqual(duck.level(at: 11.5), 0.35, accuracy: 0.001, "still ducked, never lower than depth")
        XCTAssertEqual(duck.level(at: 12.8), 1, accuracy: 0.001)
        // A clip during the release dips again from where the level is: no jump.
        let before = duck.level(at: 12.3)
        duck.duck(at: 12.3, until: 13)
        XCTAssertEqual(duck.level(at: 12.3), before, accuracy: 0.0001)
        XCTAssertEqual(duck.level(at: 12.45), 0.35, accuracy: 0.001)
        duck.reset()
        XCTAssertEqual(duck.level(at: 11), 1)
    }
}

final class LoopTrimTests: XCTestCase {
    func testExactLengthNeedsNoTrim() {
        XCTAssertNil(LoopTrim.range(decodedFrames: 1_949_696, expectedFrames: 1_949_696))
        XCTAssertNil(LoopTrim.range(decodedFrames: 100, expectedFrames: 0))
    }

    func testDropsEncoderDelayAndEndPadding() {
        XCTAssertEqual(LoopTrim.range(decodedFrames: 1_949_696 + 1024 + 300, expectedFrames: 1_949_696),
                       1024..<(1024 + 1_949_696))
        XCTAssertEqual(LoopTrim.range(decodedFrames: 1000 + 200, expectedFrames: 1000), 200..<1200)
    }
}
