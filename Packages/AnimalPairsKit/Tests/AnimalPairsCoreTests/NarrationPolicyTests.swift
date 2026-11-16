import XCTest
@testable import AnimalPairsCore

final class NarrationPolicyTests: XCTestCase {
    func testFindPairOnlyAfterALongQuietSpell() {
        var policy = NarrationPolicy()
        XCTAssertEqual(policy.roundStarted(at: 0), .findPair, "first round of a session")
        XCTAssertNil(policy.roundStarted(at: 60), "replaying soon after stays quiet")
        XCTAssertEqual(policy.roundStarted(at: 200), .findPair)
    }

    func testPraiseIsOccasional() {
        var policy = NarrationPolicy()
        var spoken: [NarrationCue] = []
        for i in 0..<12 {
            if let cue = policy.matched(at: Double(i) * 10) { spoken.append(cue) }
        }
        // 12 matches over 110 s: every 3rd match qualifies, but the 20 s gap
        // limits it further.
        XCTAssertEqual(spoken, [.greatMatch, .greatMatch, .greatMatch, .greatMatch])
        var fast = NarrationPolicy()
        let quick = (0..<9).compactMap { fast.matched(at: Double($0)) }
        XCTAssertEqual(quick.count, 1, "rapid matches never stack narration")
    }

    func testEncouragementOnlyAfterRepeatedMisses() {
        var policy = NarrationPolicy()
        XCTAssertNil(policy.missed(at: 0))
        XCTAssertNil(policy.missed(at: 5))
        XCTAssertEqual(policy.missed(at: 10), .tryAgain)
        XCTAssertNil(policy.missed(at: 11))
        XCTAssertNil(policy.missed(at: 12))
        XCTAssertNil(policy.missed(at: 13), "still inside the quiet gap")
        _ = policy.matched(at: 14) // a match resets the miss streak
        XCTAssertNil(policy.missed(at: 40))
    }

    func testCompletionNeedsOnlyAShortGap() {
        var policy = NarrationPolicy()
        _ = policy.roundStarted(at: 0)
        XCTAssertNil(policy.completed(at: 1))
        XCTAssertEqual(policy.completed(at: 4), .allDone)
    }

    func testNeverTwoLinesWithinTheGap() {
        var policy = NarrationPolicy()
        var times: [Double] = []
        var t = 0.0
        for step in 0..<200 {
            t += 0.5
            let cue: NarrationCue?
            switch step % 4 {
            case 0: cue = policy.missed(at: t)
            case 1: cue = policy.matched(at: t)
            case 2: cue = policy.missed(at: t)
            default: cue = policy.matched(at: t)
            }
            if cue != nil { times.append(t) }
        }
        for (a, b) in zip(times, times.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 20) }
    }
}
