import XCTest
@testable import AnimalPairsCore

final class SoundPlaybackPolicyTests: XCTestCase {
    private let flip = SoundRule(minInterval: 0.08, priority: 1, duration: 0.5)
    private let tap = SoundRule(minInterval: 0.12, priority: 0, duration: 0.3)
    private let match = SoundRule(minInterval: 0.2, priority: 2, duration: 1.0)
    private let complete = SoundRule(minInterval: 1.0, priority: 3, duration: 2.0)

    func testRapidRepeatsAreDroppedNotStacked() {
        var policy = SoundPlaybackPolicy()
        XCTAssertEqual(policy.request("flip", rule: flip, at: 0.00), .play(stopping: []))
        // A burst of 10 requests 20 ms apart (0.001 … 0.181 s).
        var decisions: [SoundDecision] = []
        for i in 1...10 {
            decisions.append(policy.request("flip", rule: flip, at: Double(i) * 0.02 - 0.019))
        }
        XCTAssertFalse(decisions.contains(.play(stopping: [])), "never a second layered copy")
        // At most one restart per 80 ms window; everything else is dropped.
        XCTAssertEqual(decisions.filter { $0 == .restart }.count, 2)
        XCTAssertEqual(decisions.filter { $0 == .skip(.tooSoon) }.count, 8)
        XCTAssertEqual(policy.activeEffects(at: 0.2), ["flip"], "still a single voice")
    }

    func testSameEffectRestartsInsteadOfLayering() {
        var policy = SoundPlaybackPolicy()
        _ = policy.request("flip", rule: flip, at: 0)
        XCTAssertEqual(policy.request("flip", rule: flip, at: 0.1), .restart)
        XCTAssertEqual(policy.activeEffects(at: 0.15).count, 1)
    }

    func testEffectPlaysNormallyAfterItFinishes() {
        var policy = SoundPlaybackPolicy()
        _ = policy.request("flip", rule: flip, at: 0)
        XCTAssertEqual(policy.request("flip", rule: flip, at: 0.6), .play(stopping: []))
    }

    func testVoiceLimitDropsLowPriorityAndPreemptsForHigher() {
        var policy = SoundPlaybackPolicy(maxVoices: 2)
        XCTAssertEqual(policy.request("tap", rule: tap, at: 0), .play(stopping: []))
        XCTAssertEqual(policy.request("flip", rule: flip, at: 0.01), .play(stopping: []))
        // A third low-priority sound cannot get a voice.
        XCTAssertEqual(policy.request("tap2", rule: tap, at: 0.02), .skip(.tooManyVoices))
        // A higher-priority sound takes the lowest-priority voice.
        XCTAssertEqual(policy.request("match", rule: match, at: 0.03), .play(stopping: ["tap"]))
        XCTAssertEqual(policy.activeEffects(at: 0.04), ["flip", "match"])
        XCTAssertEqual(policy.request("complete", rule: complete, at: 0.05), .play(stopping: ["flip"]))
    }

    func testEqualPriorityNeverPreempts() {
        var policy = SoundPlaybackPolicy(maxVoices: 1)
        _ = policy.request("a", rule: flip, at: 0)
        XCTAssertEqual(policy.request("b", rule: flip, at: 0.01), .skip(.tooManyVoices))
    }

    func testResetForgetsHistory() {
        var policy = SoundPlaybackPolicy()
        _ = policy.request("flip", rule: flip, at: 0)
        policy.reset()
        XCTAssertEqual(policy.request("flip", rule: flip, at: 0.01), .play(stopping: []))
    }
}
