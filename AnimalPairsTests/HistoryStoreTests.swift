import AnimalPairsCore
import XCTest
@testable import AnimalPairs

@MainActor
final class HistoryStoreTests: XCTestCase {
    func testCompletionIsStoredOnlyOnce() throws {
        let store = SwiftDataCompletionStore.inMemory()
        let summary = AppTestSupport.summary(1)
        XCTAssertTrue(try store.record(summary))
        XCTAssertFalse(try store.record(summary))
        XCTAssertEqual(try store.recentRecords().count, 1)
        XCTAssertEqual(try store.totals().roundsCompleted, 1)
    }

    func testKeepsNewest100AndTotalsForAll() throws {
        let store = SwiftDataCompletionStore.inMemory()
        for i in 0..<115 { try store.record(AppTestSupport.summary(i)) }
        let recent = try store.recentRecords()
        XCTAssertEqual(recent.count, 100)
        XCTAssertEqual(recent.first?.completedAt, Date(timeIntervalSince1970: 114 * 100 + 50))
        XCTAssertEqual(try store.totals().roundsCompleted, 115)
        XCTAssertEqual(try store.totals().pairsMatched, 115 * 3)
    }

    func testTrimmedRoundIsStillDeduplicated() throws {
        let store = SwiftDataCompletionStore.inMemory()
        let first = AppTestSupport.summary(0)
        try store.record(first)
        for i in 1...110 { try store.record(AppTestSupport.summary(i)) }
        XCTAssertFalse(try store.record(first))
        XCTAssertEqual(try store.totals().roundsCompleted, 111)
    }

    func testResetClearsHistory() throws {
        let store = SwiftDataCompletionStore.inMemory()
        try store.record(AppTestSupport.summary(1))
        try store.resetProgress()
        XCTAssertTrue(try store.recentRecords().isEmpty)
        XCTAssertEqual(try store.totals(), ProgressTotals())
    }
}
