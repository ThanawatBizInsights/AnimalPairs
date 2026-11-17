import XCTest
@testable import AnimalPairsCore

final class ManifestTests: XCTestCase {
    /// The manifest shipped in the app bundle.
    private func bundledManifestData() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AnimalPairsCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // AnimalPairsKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("AnimalPairs/Resources/ArtworkManifest.json")
        return try Data(contentsOf: url)
    }

    func testBundledManifestIsValidAndComplete() throws {
        let manifest = try ArtworkManifest.decode(try bundledManifestData())
        XCTAssertEqual(manifest.characters.count, 10)
        XCTAssertEqual(manifest.artworks.count, 80, "10 animals × 8 poses")
        XCTAssertEqual(manifest.artworks.filter { $0.tier == .free }.count, 10)
        XCTAssertEqual(Set(manifest.characters.map(\.id.rawValue)),
                       ["momo", "iris", "nori", "sprout", "mochi", "sunny", "maple", "clover", "rusty", "pebble"])
        let poses: Set<PoseID> = ["signature", "play", "nap", "wave", "celebrate", "football", "golf", "cooking"]
        for character in manifest.characters {
            let arts = manifest.artworks(for: character.id)
            XCTAssertEqual(Set(arts.map(\.poseID)), poses, "\(character.id)")
            XCTAssertFalse(arts.contains { $0.poseID == "stretch" }, "Stretch is retired")
            for art in arts {
                XCTAssertEqual(art.resourceName, "\(character.id.rawValue)_\(art.poseID.rawValue)", "consistent identifiers")
                XCTAssertEqual(art.tier, art.poseID == character.defaultPoseID ? .free : .premium)
            }
        }
    }

    func testNoDevelopmentPlaceholdersRemain() throws {
        let manifest = try ArtworkManifest.decode(try bundledManifestData())
        XCTAssertTrue(manifest.placeholderArtworks.isEmpty, "every pose has supplied artwork")
        XCTAssertTrue(manifest.isReleaseReady)
    }

    func testEveryAnimalHasAtLeastThreeClearlyDifferentPoseGroups() throws {
        let manifest = try ArtworkManifest.decode(try bundledManifestData())
        for character in manifest.characters {
            let poses = manifest.artworks(for: character.id).map(\.poseID)
            var groups: [Set<PoseID>] = []
            for pose in poses where !groups.contains(where: { $0.contains(pose) }) {
                groups.append(character.lookalikes(of: pose))
            }
            XCTAssertGreaterThanOrEqual(groups.count, 3, "\(character.id): \(groups)")
            XCTAssertFalse(character.canShareBoard(character.defaultPoseID, character.defaultPoseID))
        }
    }

    func testLookalikeGroupsMustNameRealPoses() {
        let base = Fixtures.manifest()
        var chars = base.characters
        chars[0] = CharacterDefinition(id: chars[0].id, nameKey: chars[0].nameKey, speciesKey: chars[0].speciesKey,
                                       defaultPoseID: "signature", lookalikePoseGroups: [["signature", "dance"]])
        let bad = ArtworkManifest(manifestVersion: "x", characters: chars, artworks: base.artworks)
        XCTAssertThrowsError(try bad.validate()) {
            XCTAssertEqual($0 as? ManifestError, .invalidLookalikeGroup(chars[0].id, "dance"))
        }
        chars[0] = CharacterDefinition(id: chars[0].id, nameKey: chars[0].nameKey, speciesKey: chars[0].speciesKey,
                                       defaultPoseID: "signature", lookalikePoseGroups: [["signature", "play"], ["play"]])
        XCTAssertThrowsError(try ArtworkManifest(manifestVersion: "x", characters: chars, artworks: base.artworks).validate())
    }

    /// Every supported board in both modes, many times, with the bundled
    /// manifest: right pair count, two copies of one asset per pair, Exact Pose
    /// never deals two look-alike poses of one animal, Classic one pose per animal.
    func testEveryBoardSizeAndModeWithTheBundledPoses() throws {
        let manifest = try ArtworkManifest.decode(try bundledManifestData())
        let catalog = ContentCatalog(manifest: manifest, installedAssets: Set(manifest.artworks.map(\.assetID)))
        var rng = SeededGenerator(seed: 7)
        var posesSeen = Set<AssetID>()
        for mode in GameMode.allCases {
            for size in BoardSize.allCases {
                for _ in 0..<200 {
                    let tiles = try DeckBuilder.makeBoard(configuration: GameConfiguration(mode: mode, boardSize: size),
                                                          catalog: catalog, policy: ContentAccessPolicy(level: .fullGame),
                                                          using: &rng)
                    XCTAssertEqual(tiles.count, size.cardCount)
                    let byKey = Dictionary(grouping: tiles, by: \.pairKey)
                    XCTAssertEqual(byKey.count, size.pairCount)
                    XCTAssertTrue(byKey.values.allSatisfy { $0.count == 2 }, "two copies of the same asset per pair")
                    let arts = byKey.keys.compactMap(manifest.artwork)
                    posesSeen.formUnion(byKey.keys)
                    let byAnimal = Dictionary(grouping: arts, by: \.characterID)
                    switch mode {
                    case .classic:
                        XCTAssertTrue(byAnimal.values.allSatisfy { $0.count == 1 }, "one picture per animal")
                    case .exactPose:
                        for (animal, poses) in byAnimal where poses.count > 1 {
                            let def = try XCTUnwrap(manifest.character(animal))
                            XCTAssertEqual(poses.count, 2)
                            XCTAssertTrue(def.canShareBoard(poses[0].poseID, poses[1].poseID),
                                          "\(animal): \(poses[0].poseID) and \(poses[1].poseID) look alike")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(posesSeen.count, 80, "every imported pose can be dealt")
        XCTAssertFalse(posesSeen.contains { $0.rawValue.hasSuffix(".stretch") }, "Stretch is never dealt")
    }

    func testValidationCatchesStructuralProblems() {
        var m = Fixtures.manifest()
        XCTAssertNoThrow(try m.validate())

        let dupe = ArtworkManifest(manifestVersion: "x", characters: m.characters, artworks: m.artworks + [m.artworks[0]])
        XCTAssertThrowsError(try dupe.validate()) { XCTAssertEqual($0 as? ManifestError, .duplicateAsset(m.artworks[0].assetID)) }

        let orphan = ArtworkDefinition(assetID: "ghost.signature", characterID: "ghost", poseID: "signature", version: 1,
                                       resourceName: "art_ghost", accessibilityKey: "art.ghost", tier: .free, status: .final)
        let withOrphan = ArtworkManifest(manifestVersion: "x", characters: m.characters, artworks: m.artworks + [orphan])
        XCTAssertThrowsError(try withOrphan.validate())

        m = ArtworkManifest(schemaVersion: 2, manifestVersion: "x", characters: m.characters, artworks: m.artworks)
        XCTAssertThrowsError(try m.validate()) { XCTAssertEqual($0 as? ManifestError, .unsupportedSchema(2)) }

        let noDefault = Fixtures.manifest(poses: ["play", "nap"])
        XCTAssertThrowsError(try noDefault.validate())
    }

    func testPairKeyIsTheArtworkIdentity() throws {
        let manifest = try ArtworkManifest.decode(try bundledManifestData())
        XCTAssertEqual(Set(manifest.artworks.map(\.assetID)).count, 80)
        XCTAssertEqual(Set(manifest.artworks.map(\.resourceName)).count, 80, "one saved resource per pair key")
    }
}
