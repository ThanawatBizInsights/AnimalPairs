@testable import AnimalPairsCore
import XCTest

final class BoardLayoutTests: XCTestCase {
    private let aspect = 0.735

    private func layout(_ board: BoardSize, _ width: Double, _ height: Double) -> BoardLayout {
        BoardLayout(width: width, height: height, columns: board.columns, rows: board.rows, aspect: aspect)
    }

    private func assertUsable(_ l: BoardLayout, _ width: Double, _ height: Double,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(l.cardWidth, BoardLayout.minimumCardWidth - 1e-9, "tap target", file: file, line: line)
        XCTAssertEqual(l.cardWidth / l.cardHeight, aspect, accuracy: 1e-9, "card proportions", file: file, line: line)
        // Everything is reachable: either it fits, or it scrolls on the axis that does not.
        XCTAssertTrue(l.contentWidth <= width + 0.5 || l.scrollsHorizontally, file: file, line: line)
        XCTAssertTrue(l.contentHeight <= height + 0.5 || l.scrollsVertically, file: file, line: line)
    }

    func testFullScreenIPadAndPortraitIPhoneFitWithoutScrolling() {
        for (w, h) in [(992.0, 640.0), (1336, 860), (343, 470), (390, 560)] {   // iPad landscape, iPad 13", iPhone SE/15 portrait
            let l = layout(.twenty, w, h)
            XCTAssertTrue(l.fitsWithoutScrolling, "\(w)×\(h)")
            assertUsable(l, w, h)
        }
    }

    func testCompactLandscapeIPhoneScrollsVerticallyInsteadOfShrinking() {
        let (w, h) = (620.0, 190.0)                 // landscape iPhone after header and Hint
        let l = layout(.twenty, w, h)
        XCTAssertTrue(l.scrollsVertically)
        XCTAssertFalse(l.scrollsHorizontally, "five columns still fit across")
        assertUsable(l, w, h)
    }

    func testNarrowIPadWindowAndLargeTextStayReachable() {
        for (w, h) in [(260.0, 700.0), (320, 230), (300, 120)] {   // Slide Over, Split View at AX sizes
            let l = layout(.twenty, w, h)
            assertUsable(l, w, h)
        }
        XCTAssertTrue(layout(.twenty, 200, 700).scrollsHorizontally, "too narrow for five 52-pt cards")
    }

    func testCardsNeverMove(){
        // The same index is at the same row/column whatever the size.
        let sizes = [(992.0, 640.0), (620, 190), (200, 700)]
        for index in 0..<20 {
            let positions = sizes.map { layout(.twenty, $0.0, $0.1).position(of: index) }
            XCTAssertTrue(positions.allSatisfy { $0 == positions[0] })
            XCTAssertEqual(positions[0].row, index / 5)
            XCTAssertEqual(positions[0].column, index % 5)
        }
    }

    func testSmallerBoardsAreUnchangedWhereTheyAlreadyFit() {
        let l = layout(.six, 343, 470)
        XCTAssertTrue(l.fitsWithoutScrolling)
        XCTAssertGreaterThan(l.cardWidth, 90)
    }

    func testDegenerateSizesDoNotCrash() {
        let l = layout(.twenty, 0, 0)
        XCTAssertEqual(l.cardWidth, BoardLayout.minimumCardWidth)
        XCTAssertTrue(l.scrollsVertically && l.scrollsHorizontally)
    }
}
