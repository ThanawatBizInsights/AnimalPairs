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
        XCTAssertEqual(manifest.artworks.count, 30, "30 launch animal-pose illustrations")
        XCTAssertEqual(manifest.artworks.filter { $0.tier == .free }.count, 10)
        XCTAssertEqual(Set(manifest.characters.map(\.id.rawValue)),
                       ["momo", "luna", "nori", "sprout", "mochi", "sunny", "maple", "clover", "rusty", "pebble"])
        for character in manifest.characters {
            XCTAssertEqual(manifest.artworks.filter { $0.characterID == character.id }.count, 3)
        }
    }

    func testBundledManifestHonestlyReportsPlaceholders() throws {
        let manifest = try ArtworkManifest.decode(try bundledManifestData())
        // Only the ten supplied signature illustrations are final today.
        XCTAssertEqual(manifest.artworks.filter { $0.status == .final }.count, 10)
        XCTAssertFalse(manifest.isReleaseReady, "update this test when final pose art lands")
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
        XCTAssertEqual(Set(manifest.artworks.map(\.assetID)).count, 30)
        XCTAssertEqual(Set(manifest.artworks.map(\.resourceName)).count, 30, "one saved resource per pair key")
    }
}
