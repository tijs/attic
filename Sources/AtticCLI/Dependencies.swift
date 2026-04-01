import Foundation
import AtticCore
import LadderKit

/// Builds the real dependencies for CLI commands from config + keychain.
enum Dependencies {
    /// Load config from default location, or throw with a helpful message.
    static func loadConfig() throws -> AtticConfig {
        let provider = FileConfigProvider()
        guard let config = try provider.load() else {
            throw CLIError.notInitialized
        }
        return config
    }

    /// Load credentials from the macOS Keychain.
    static func loadCredentials(config: AtticConfig) throws -> S3Credentials {
        let keychain = SecurityKeychain()
        return try keychain.loadCredentials(
            accessKeyService: config.keychain.accessKeyService,
            secretKeyService: config.keychain.secretKeyService
        )
    }

    /// Create an S3 client from config + credentials.
    static func makeS3Client(config: AtticConfig, credentials: S3Credentials) throws -> URLSessionS3Client {
        try URLSessionS3Client(
            credentials: credentials,
            bucket: config.bucket,
            endpoint: config.endpoint,
            region: config.region,
            pathStyle: config.pathStyle
        )
    }

    /// Create the full set of backup dependencies.
    static func makeBackupDeps() throws -> (
        config: AtticConfig,
        s3: URLSessionS3Client,
        manifestStore: S3ManifestStore
    ) {
        let config = try loadConfig()
        let creds = try loadCredentials(config: config)
        let s3 = try makeS3Client(config: config, credentials: creds)
        let manifestStore = S3ManifestStore(s3: s3)
        return (config, s3, manifestStore)
    }

    /// Load manifest with automatic migration from local file if needed.
    ///
    /// On first run after upgrading from the Deno CLI, this detects a local
    /// `~/.attic/manifest.json`, uploads it to S3, and returns it. Subsequent
    /// runs use the S3 manifest directly.
    static func loadManifest(store: S3ManifestStore) async throws -> Manifest {
        try await loadManifestWithMigration(s3Store: store)
    }

    /// Default system Photos library location.
    static var defaultLibraryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures")
            .appendingPathComponent("Photos Library.photoslibrary")
    }

    /// Load assets from PhotoKit + enrich from Photos.sqlite.
    static func loadAssets() -> [AssetInfo] {
        let library = PhotoKitLibrary()
        var assets = library.enumerateAssets()

        if let dbPath = PhotosLibraryPath.databasePath(for: defaultLibraryURL) {
            let enrichment = PhotosDatabase.readEnrichment(dbPath: dbPath)
            PhotosDatabase.enrich(&assets, with: enrichment)
        }

        return assets
    }
}

enum CLIError: Error, CustomStringConvertible {
    case notInitialized

    var description: String {
        switch self {
        case .notInitialized:
            "Attic is not configured. Run 'attic init' first."
        }
    }
}
