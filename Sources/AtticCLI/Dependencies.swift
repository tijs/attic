import AtticCore
import Foundation
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
            secretKeyService: config.keychain.secretKeyService,
        )
    }

    /// Create an S3 client from config + credentials.
    static func makeS3Client(config: AtticConfig, credentials: S3Credentials) throws -> URLSessionS3Client {
        try URLSessionS3Client(
            credentials: credentials,
            bucket: config.bucket,
            endpoint: config.endpoint,
            region: config.region,
            pathStyle: config.pathStyle,
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

    /// Load the set of asset UUIDs whose originals are cached locally (fast
    /// lane). Returns `nil` if the Photos.sqlite can't be located or read — the
    /// exporter then treats everything as cloud-only, which is safe but slower.
    static func loadLocalAvailability() -> (any LocalAvailabilityProviding)? {
        guard let dbPath = PhotosLibraryPath.databasePath(for: defaultLibraryURL) else {
            return nil
        }
        let localUUIDs = PhotosDatabase.localAvailableUUIDs(dbPath: dbPath)
        return PhotosDatabaseLocalAvailability(localUUIDs: localUUIDs)
    }

    /// Build a fully-wired migration runner using real PhotoKit, S3, retry,
    /// and unavailable stores. Caller owns prompting / confirmation flow.
    static func makeMigrationRunner(
        progress: MigrationRunner.ProgressHandler? = nil,
    ) async throws -> MigrationRunner {
        let (_, s3, manifestStore) = try makeBackupDeps()
        let library = PhotoKitLibrary()
        let resolver = PhotoKitCloudIdentityResolver()
        let retry = FileRetryQueueStore()
        let unavailable = FileUnavailableAssetStore()

        let identifiers: @Sendable () -> [(bareUUID: String, fullLocalIdentifier: String)] = {
            library.enumerateAssets().map {
                (bareUUID: $0.uuid, fullLocalIdentifier: $0.identifier)
            }
        }

        return MigrationRunner(
            s3: s3,
            manifestStore: manifestStore,
            resolver: resolver,
            assetIdentifierProvider: identifiers,
            retryStore: retry,
            unavailableStore: unavailable,
            progress: progress,
        )
    }

    /// Delete any leftover migration staging key on S3.
    static func deleteMigrationStagingKey() async throws {
        let (_, s3, _) = try makeBackupDeps()
        try? await s3.deleteObject(key: manifestV2StagingS3Key)
    }

    /// Guard that runs at the top of every command needing a v2 manifest.
    /// Detects v1, prompts the user (TTY), runs migration with progress,
    /// or fails fast on non-TTY with a clear next-step message.
    static func ensureManifestMigrated() async throws {
        let isTTY = isatty(STDOUT_FILENO) != 0 && isatty(STDIN_FILENO) != 0
        let (_, _, manifestStore) = try makeBackupDeps()
        let manifest = try await loadManifest(store: manifestStore)
        guard manifest.isV1 else { return }

        let count = manifest.entries.count
        FileHandle.standardError.write(Data("""

        attic detected a v1 manifest (\(count) entries) keyed by device-local
        PhotoKit identifiers. attic 1.0.0-beta.8 requires a one-time migration
        to cross-device cloud identifiers before continuing.


        """.utf8))

        guard isTTY else {
            FileHandle.standardError.write(Data(
                "Re-run `attic migrate --yes` from an interactive shell to perform the migration.\n\n".utf8,
            ))
            throw CLIError.migrationRequired
        }

        print("Run migration now? [Y/n] ", terminator: "")
        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !answer.isEmpty, !["y", "yes"].contains(answer) {
            throw CLIError.migrationRequired
        }

        let runner = try await makeMigrationRunner(progress: { msg in print("  \(msg)") })
        let report = try await runner.run()
        print("")
        print("Migration complete: \(report.cloudMigrated) cloud, \(report.localFallback) local fallback.")
        print("")
    }
}

enum CLIError: Error, CustomStringConvertible {
    case notInitialized
    case migrationRequired

    var description: String {
        switch self {
        case .notInitialized:
            "Attic is not configured. Run 'attic init' first."
        case .migrationRequired:
            "Manifest migration to v2 is required before this command can run."
        }
    }
}
