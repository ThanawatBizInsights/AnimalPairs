import XCTest
@testable import AnimalPairsCore

final class DeckBuilderTests: XCTestCase {
    private func board(_ mode: GameMode, _ size: BoardSize, seed: UInt64,
                       policy: ContentAccessPolicy = Fixtures.full,
                       catalog: ContentCatalog = Fixtures.catalog()) throws -> [Tile] {
        var rng = SeededGenerator(seed: seed)
        return try DeckBuilder.makeBoard(configuration: GameConfiguration(mode: mode, boardSize: size),
                                         catalog: catalog, policy: policy, using: &rng)
    }

    func testBoardGeometry() {
        XCTAssertEqual(BoardSize.six.columns * BoardSize.six.rows, 6)
        XCTAssertEqual([BoardSize.six.columns, BoardSize.six.rows], [3, 2])
        XCTAssertEqual([BoardSize.twelve.columns, BoardSize.twelve.rows], [4, 3])
        XCTAssertEqual([BoardSize.sixteen.columns, BoardSize.sixteen.rows], [4, 4])
        XCTAssertEqual([BoardSize.twenty.columns, BoardSize.twenty.rows], [5, 4])
        for size in BoardSize.allCases { XCTAssertEqual(size.columns * size.rows, size.cardCount) }
    }

    func testEveryPairKeyAppearsExactlyTwiceWithUniqueTileIDs() throws {
        for mode in GameMode.allCases {
            for size in BoardSize.allCases {
                for seed in 0..<40 as Range<UInt64> {
                    let tiles = try board(mode, size, seed: seed)
                    XCTAssertEqual(tiles.count, size.cardCount, "\(mode) \(size)")
                    XCTAssertEqual(Set(tiles.map(\.id)).count, tiles.count, "tile IDs must be unique")
                    let counts = Dictionary(grouping: tiles, by: \.pairKey).mapValues(\.count)
                    XCTAssertEqual(counts.count, size.pairCount)
                    XCTAssertTrue(counts.values.allSatisfy { $0 == 2 }, "\(mode) \(size) seed \(seed)")
                    XCTAssertTrue(tiles.allSatisfy { $0.face == .covered })
                }
            }
        }
    }

    func testClassicUsesDistinctAnimalsOnePoseEach() throws {
        let manifest = Fixtures.manifest()
        for size in BoardSize.allCases {
            for seed in 0..<40 as Range<UInt64> {
                let tiles = try board(.classic, size, seed: seed)
                let keys = Set(tiles.map(\.pairKey))
                let characters = keys.map { manifest.artwork($0)!.characterID }
                XCTAssertEqual(Set(characters).count, keys.count, "one pose per animal")
            }
        }
    }

    func testExactPoseWithSixOrMorePairsHasTwoAnimalsInTwoPoses() throws {
        let manifest = Fixtures.manifest()
        for size in [BoardSize.twelve, .sixteen, .twenty] {
            for seed in 0..<60 as Range<UInt64> {
                let tiles = try board(.exactPose, size, seed: seed)
                let keys = Set(tiles.map(\.pairKey))
                let posesPerAnimal = Dictionary(grouping: keys, by: { manifest.artwork($0)!.characterID })
                    .mapValues { Set($0.map { manifest.artwork($0)!.poseID }).count }
                XCTAssertGreaterThanOrEqual(posesPerAnimal.values.filter { $0 >= 2 }.count, 2,
                                            "\(size) seed \(seed): \(posesPerAnimal)")
            }
        }
    }

    func testExactPoseThreePairsIsTwoPosesOfOneAnimalPlusAnother() throws {
        let manifest = Fixtures.manifest()
        for seed in 0..<60 as Range<UInt64> {
            let keys = Set(try board(.exactPose, .six, seed: seed).map(\.pairKey))
            let grouped = Dictionary(grouping: keys, by: { manifest.artwork($0)!.characterID }).mapValues(\.count)
            XCTAssertEqual(grouped.values.sorted(), [1, 2], "seed \(seed): \(grouped)")
        }
    }

    func testSeededShuffleIsReproducibleAndVaries() throws {
        let a = try board(.classic, .twenty, seed: 7)
        let b = try board(.classic, .twenty, seed: 7)
        let c = try board(.classic, .twenty, seed: 8)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a.map(\.pairKey), c.map(\.pairKey))
    }

    func testStarterCannotBuildPremiumConfigurations() {
        XCTAssertThrowsError(try board(.exactPose, .six, seed: 1, policy: Fixtures.starter))
        XCTAssertThrowsError(try board(.classic, .sixteen, seed: 1, policy: Fixtures.starter))
        XCTAssertThrowsError(try board(.classic, .twenty, seed: 1, policy: Fixtures.starter))
    }

    func testStarterUsesOnlyDefaultPoses() throws {
        let manifest = Fixtures.manifest()
        for seed in 0..<40 as Range<UInt64> {
            for size in [BoardSize.six, .twelve] {
                let tiles = try board(.classic, size, seed: seed, policy: Fixtures.starter)
                XCTAssertTrue(tiles.allSatisfy { manifest.artwork($0.pairKey)!.tier == .free })
            }
        }
    }

    func testMissingArtworkIsNeverDealt() throws {
        let missing: Set<AssetID> = ["momo.signature", "iris.play", "nori.nap"]
        for seed in 0..<40 as Range<UInt64> {
            let tiles = try board(.exactPose, .twenty, seed: seed, catalog: Fixtures.catalog(missing: missing))
            XCTAssertTrue(Set(tiles.map(\.pairKey)).isDisjoint(with: missing))
        }
    }

    func testInsufficientContentThrowsInsteadOfDuplicating() {
        let small = Fixtures.manifest(characters: ["momo", "iris"], poses: ["signature"])
        XCTAssertThrowsError(try board(.classic, .six, seed: 1, catalog: Fixtures.catalog(small))) { error in
            XCTAssertEqual(error as? DeckBuilderError, .notEnoughCharacters(needed: 3, available: 2))
        }
        let onePose = Fixtures.manifest(poses: ["signature"])
        XCTAssertThrowsError(try board(.exactPose, .twelve, seed: 1, catalog: Fixtures.catalog(onePose))) { error in
            XCTAssertEqual(error as? DeckBuilderError, .notEnoughPoseVariety(needed: 2, available: 0))
        }
    }

    func testStarterContentCountsFromBundledRules() {
        let catalog = Fixtures.catalog()
        XCTAssertEqual(catalog.playableArtworks(for: Fixtures.starter).count, 10)
        XCTAssertEqual(catalog.playableArtworks(for: Fixtures.full).count, 30)
        XCTAssertEqual(catalog.playableCharacters(for: Fixtures.starter).count, 10)
    }
}
