import Foundation

public enum GameMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Distinct animals, one pose per animal.
    case classic
    /// Several poses of the same animal; a pair must match animal *and* pose.
    case exactPose

    public var id: String { rawValue }
}

public enum BoardSize: Int, Codable, Sendable, CaseIterable, Identifiable, Comparable {
    case six = 6
    case twelve = 12
    case sixteen = 16
    case twenty = 20

    public var id: Int { rawValue }
    public var cardCount: Int { rawValue }
    public var pairCount: Int { rawValue / 2 }

    /// Fixed grid. Layout may scale cards but never reorders them.
    public var columns: Int {
        switch self {
        case .six: 3
        case .twelve: 4
        case .sixteen: 4
        case .twenty: 5
        }
    }

    public var rows: Int {
        switch self {
        case .six: 2
        case .twelve: 3
        case .sixteen: 4
        case .twenty: 4
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct GameConfiguration: Codable, Hashable, Sendable {
    public var mode: GameMode
    public var boardSize: BoardSize

    public init(mode: GameMode, boardSize: BoardSize) {
        self.mode = mode
        self.boardSize = boardSize
    }

    public static let starter = GameConfiguration(mode: .classic, boardSize: .six)
}
