import Foundation

/// Source of the artwork manifest. The launch game uses a bundled repository;
/// a future remote repository can conform without touching game code.
public protocol ContentRepository: Sendable {
    func loadManifest() async throws -> ArtworkManifest
    /// Asset IDs whose image resources are present on this device.
    func installedAssets(for manifest: ArtworkManifest) async -> Set<AssetID>
}

/// Wire format of the optional backend's public catalog endpoint
/// (`GET /v1/catalog`). Not used by the launch build.
public struct RemoteCatalogResponse: Codable, Equatable, Sendable {
    public struct ManifestReference: Codable, Equatable, Sendable {
        public let manifestVersion: String
        public let schemaVersion: Int
        public let publishedAt: Date
        public let manifestPath: String
    }

    public let catalogVersion: Int
    public let latest: ManifestReference?
}

/// Request body for `POST /v1/assets/{assetID}/download`. Premium content
/// requires the StoreKit signed transaction (JWS); the server verifies it with
/// Apple's libraries and fails closed. No gameplay data is ever sent.
public struct AssetDownloadRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let signedTransaction: String?

    public init(version: Int, signedTransaction: String?) {
        self.version = version
        self.signedTransaction = signedTransaction
    }
}

public struct AssetDownloadResponse: Codable, Equatable, Sendable {
    public let url: URL
    public let expiresAt: Date
    public let sha256: String
}

/// Contract for a future remote content client.
public protocol RemoteContentClient: Sendable {
    func fetchCatalog() async throws -> RemoteCatalogResponse
    func fetchManifest(version: String) async throws -> ArtworkManifest
    func requestDownload(asset: AssetID, request: AssetDownloadRequest) async throws -> AssetDownloadResponse
}

/// Decoding helpers shared by any HTTP implementation.
public enum RemoteContentCoding {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
