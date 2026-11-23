import Foundation

/// Size and spacing of the cards for a board in the space available. Pure,
/// so it is tested on its own; `CardGrid` (app) draws it.
///
/// * The board's own columns and rows are always kept (`BoardSize`), so a
///   card never changes position when the window or text size changes —
///   important in a memory game.
/// * Cards keep the card-back proportions (`aspect`, width ÷ height).
/// * Cards are as large as fit. When fitting would make them smaller than
///   `minimumCardWidth` (a usable tap target for small hands), they stay at
///   that minimum and the grid scrolls in the direction that does not fit —
///   e.g. a 20-card board on a compact landscape iPhone, in a short iPad
///   window or at accessibility text sizes. Every card stays reachable.
public struct BoardLayout: Equatable, Sendable {
    /// Smallest card width used before scrolling (height = width ÷ aspect).
    public static let minimumCardWidth: Double = 52

    public let columns: Int
    public let rows: Int
    public let cardWidth: Double
    public let cardHeight: Double
    public let spacing: Double
    /// Size of the whole grid of cards.
    public let contentWidth: Double
    public let contentHeight: Double
    public let scrollsHorizontally: Bool
    public let scrollsVertically: Bool

    public var fitsWithoutScrolling: Bool { !scrollsHorizontally && !scrollsVertically }

    public init(width: Double, height: Double, columns: Int, rows: Int, aspect: Double,
                minimumCardWidth: Double = BoardLayout.minimumCardWidth) {
        let columns = max(1, columns), rows = max(1, rows)
        let width = max(0, width), height = max(0, height)
        self.columns = columns
        self.rows = rows
        spacing = min(18, max(6, min(width, height) * 0.02))
        let cellWidth = (width - spacing * Double(columns - 1)) / Double(columns)
        let cellHeight = (height - spacing * Double(rows - 1)) / Double(rows)
        let fitted = min(cellWidth, cellHeight * aspect)
        cardWidth = max(minimumCardWidth, fitted)
        cardHeight = cardWidth / aspect
        contentWidth = cardWidth * Double(columns) + spacing * Double(columns - 1)
        contentHeight = cardHeight * Double(rows) + spacing * Double(rows - 1)
        let tolerance = 0.5
        scrollsHorizontally = contentWidth > width + tolerance
        scrollsVertically = contentHeight > height + tolerance
    }

    /// Row and column of the card at `index` in board order (row-major).
    public func position(of index: Int) -> (row: Int, column: Int) {
        (index / columns, index % columns)
    }
}
