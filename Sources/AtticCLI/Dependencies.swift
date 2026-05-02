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

    /// Load assets from PhotoKit + enrich from Photos.sqlite, without
    /// resolving cloud identity. Internal helper for ``loadAssetsAsync`` —
    /// command call sites should use the async form.
    private static func loadAssets() -> [AssetInfo] {
        let library = PhotoKitLibrary()
        var assets = library.enumerateAssets()

        if let dbPath = PhotosLibraryPath.databasePath(for: defaultLibraryURL) {
            let enrichment = PhotosDatabase.readEnrichment(dbPath: dbPath)
            PhotosDatabase.enrich(&assets, with: enrichment)
        }

        return assets
    }

    /// Load assets and resolve cloud-stable identity for each via PhotoKit's
    /// `cloudIdentifierMappings` API. Falls back to local UUID for assets
    /// without a cloud counterpart. Logs a warning when more than 5% of
    /// assets fail resolution — a strong signal that iCloud Photos is
    /// disabled or PhotoKit consent is incomplete.
    static func loadAssetsAsync() async -> [AssetInfo] {
        let assets = loadAssets()
        guard !assets.isEmpty else { return assets }

        let resolver = PhotoKitCloudIdentityResolver()
        let identifiers = assets.map(\.identifier)
        let mapping = await resolver.resolve(localIdentifiers: identifiers)

        var unresolved = 0
        let resolved: [AssetInfo] = assets.map { asset in
            if let result = mapping[asset.identifier] {
                if case .cloud = result {
                    return asset.withResolvedCloudIdentity(result)
                }
                unresolved += 1
            } else {
                unresolved += 1
            }
            return asset
        }

        if !assets.isEmpty {
            let pct = Double(unresolved) / Double(assets.count) * 100
            if pct > 5.0 {
                FileHandle.standardError.write(Data("""
                Warning: \(unresolved) of \(assets.count) assets (\(String(format: "%.1f", pct))%) \
                have no cloud identifier. Cross-device backup recognition will not work for those assets. \
                Verify iCloud Photos is enabled and PhotoKit access is granted to attic.

                """.utf8))
            }
        }

        return resolved
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

    /// Delete any leftover migration lock on S3 (e.g. orphaned by a crash on
    /// another machine).
    static func deleteMigrationLock() async throws {
        let (_, s3, _) = try makeBackupDeps()
        try? await s3.deleteObject(key: migrationLockS3Key)
    }

    /// Inspect migration cleanup state without mutating it. Returns a
    /// human-readable summary for the CLI to print before `--repair` deletes
    /// anything, so the user can recognize when a "stale" lock is actually
    /// a migration in flight elsewhere.
    static func describeMigrationCleanupState() async throws -> String {
        let (_, s3, _) = try makeBackupDeps()
        var lines: [String] = []

        if try await s3.headObject(key: manifestV2StagingS3Key) != nil {
            lines.append("  - Staging key: \(manifestV2StagingS3Key) present")
        } else {
            lines.append("  - Staging key: not present")
        }

        let lock = MigrationLock(s3: s3)
        if let body = try await lock.readExisting() {
            lines.append("  - Lock: held by \(body.machineId), started \(body.startedAt) (ttl=\(body.ttlSeconds)s)")
        } else {
            lines.append("  - Lock: not present")
        }
        return lines.joined(separator: "\n")
    }

    /// Guard that runs at the top of every command needing a v2 manifest.
    /// Detects v1, prompts the user (TTY), runs migration with progress,
    /// or fails fast on non-TTY with a clear next-step message.
    static func ensureManifestMigrated() async throws {
        let isTTY = isatty(STDOUT_FILENO) != 0 && isatty(STDIN_FILENO) != 0
        let (_, _, manifestStore) = try makeBackupDeps()
        let manifest = try await loadManifest(store: manifestStore)
        guard manifest.isV1 else { return }

        FileHandle.standardError.write(Data(MigrationPrompt.message(count: manifest.entries.count).utf8))

        let decision = MigrationPrompt.decide(
            isTTY: isTTY,
            answer: { isTTY ? readLine() : nil },
        )

        switch decision {
        case .nonInteractive:
            FileHandle.standardError.write(Data(MigrationPrompt.nonInteractiveHint.utf8))
            throw CLIError.migrationRequired
        case .abort:
            throw CLIError.migrationRequired
        case .proceed:
            let runner = try await makeMigrationRunner(progress: { msg in print("  \(msg)") })
            let report = try await runner.run()
            print("")
            print("Migration complete: \(report.cloudMigrated) cloud, \(report.localFallback) local fallback.")
            print("")
        }
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
