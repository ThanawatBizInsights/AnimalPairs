import AnimalPairsCore
import SwiftUI
import UIKit

/// Loads the bundled manifest and checks which image resources really exist.
struct BundledContentRepository: ContentRepository {
    let bundle: Bundle

    init(bundle: Bundle = .main) { self.bundle = bundle }

    enum LoadError: Error { case manifestMissing }

    func loadManifest() async throws -> ArtworkManifest {
        try loadManifestSync()
    }

    func loadManifestSync() throws -> ArtworkManifest {
        guard let url = bundle.url(forResource: "ArtworkManifest", withExtension: "json") else { throw LoadError.manifestMissing }
        return try ArtworkManifest.decode(Data(contentsOf: url))
    }

    func installedAssets(for manifest: ArtworkManifest) async -> Set<AssetID> {
        installedAssetsSync(for: manifest)
    }

    func installedAssetsSync(for manifest: ArtworkManifest) -> Set<AssetID> {
        Set(manifest.artworks.filter { UIImage(named: $0.resourceName, in: bundle, with: nil) != nil }.map(\.assetID))
    }
}

/// The single place that turns an artwork definition into pixels. Both cards
/// of a pair call this with the same definition and so show the same file.
struct ArtworkImage: View {
    let artwork: ArtworkDefinition?

    var body: some View {
        if let artwork, UIImage(named: artwork.resourceName) != nil {
            Image(artwork.resourceName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            // Missing resource: a neutral marker instead of a crash. Rounds
            // are never dealt with missing art; this only guards rendering.
            Image(systemName: "questionmark.square.dashed")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Palette.lavenderDeep)
                .padding(24)
        }
    }
}
