import AtticCore
import Foundation
import LadderKit

/// Builds the real dependencies for CLI commands from config + keychain.
enum Dependencies {
    /// Load config from default location, or throw with a helpful message.
    static func loadConfig(profile: String? = nil) throws -> AtticConfig {
        let provider = try FileConfigProvider(directory: AtticProfile(name: profile).directory)
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
            storageClass: config.storageClass,
        )
    }

    /// Create the full set of backup dependencies.
    static func makeBackupDeps(profile: String? = nil) throws -> (
        config: AtticConfig,
        s3: any ObjectProviding,
        manifestStore: ObjectManifestStore
    ) {
        let config = try loadConfig(profile: profile)
        let s3: any ObjectProviding = if let destination = config.filesystem {
            try FilesystemObjectStore(destination: destination)
        } else {
            try makeS3Client(config: config, credentials: loadCredentials(config: config))
        }
        let state = try AtticProfile(name: profile).stateDirectory(config: config)
        let legacyState = config.filesystem == nil && profile == nil && state == FileConfigProvider.defaultDirectory
        let manifestStore = ObjectManifestStore(s3: s3, allowsLegacyLocalMigration: legacyState)
        return (config, s3, manifestStore)
    }

    /// Load manifest with automatic migration from local file if needed.
    ///
    /// On first run after upgrading from the Deno CLI, this detects a local
    /// `~/.attic/manifest.json`, uploads it to S3, and returns it. Subsequent
    /// runs use the S3 manifest directly.
    static func loadManifest(store: S3ManifestStore, localDirectory: URL? = nil) async throws -> Manifest {
        if store.allowsLegacyLocalMigration {
            try await loadManifestWithMigration(s3Store: store, localDirectory: localDirectory)
        } else {
            try await store.load()
        }
    }

    static func stateDirectory(profile: String? = nil) throws -> URL {
        try AtticProfile(name: profile).stateDirectory(config: loadConfig(profile: profile))
    }

    static func requireS3Migration(profile: String? = nil) throws {
        guard try loadConfig(profile: profile).filesystem == nil else {
            throw ConfigError
                .invalid("S3 migration/repair is not supported for filesystem destinations (initialized as v2)")
        }
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
    static func loadAssetsAsync() async throws -> [AssetInfo] {
        try await PhotosPermissionAuthorizer.preflight()

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
        profile: String? = nil,
    ) async throws -> MigrationRunner {
        try requireS3Migration(profile: profile)
        try await PhotosPermissionAuthorizer.preflight()

        let (config, s3, manifestStore) = try makeBackupDeps(profile: profile)
        let library = PhotoKitLibrary()
        let resolver = PhotoKitCloudIdentityResolver()
        let state = try AtticProfile(name: profile).stateDirectory(config: config)
        let retry = FileRetryQueueStore(directory: state)
        let unavailable = FileUnavailableAssetStore(directory: state)

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
    static func deleteMigrationStagingKey(profile: String? = nil) async throws {
        try requireS3Migration(profile: profile)
        let (_, s3, _) = try makeBackupDeps(profile: profile)
        try? await s3.deleteObject(key: manifestV2StagingS3Key)
    }

    /// Delete any leftover migration lock on S3 (e.g. orphaned by a crash on
    /// another machine).
    static func deleteMigrationLock(profile: String? = nil) async throws {
        try requireS3Migration(profile: profile)
        let (_, s3, _) = try makeBackupDeps(profile: profile)
        try? await s3.deleteObject(key: migrationLockS3Key)
    }

    /// Inspect migration cleanup state without mutating it. Returns a
    /// human-readable summary for the CLI to print before `--repair` deletes
    /// anything, so the user can recognize when a "stale" lock is actually
    /// a migration in flight elsewhere.
    static func describeMigrationCleanupState(profile: String? = nil) async throws -> String {
        try requireS3Migration(profile: profile)
        let (_, s3, _) = try makeBackupDeps(profile: profile)
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
    /// See ``MigrationGuard`` for the control flow. With `statusToStderr`
    /// (JSON mode), progress and completion output is routed to stderr so
    /// stdout stays reserved for the machine-readable document.
    static func ensureManifestMigrated(statusToStderr: Bool = false, profile: String? = nil) async throws {
        if try loadConfig(profile: profile).filesystem != nil {
            let (_, _, store) = try makeBackupDeps(profile: profile)
            guard try await store.load().version == currentManifestVersion else {
                throw ConfigError
                    .invalid("Filesystem destination requires a v2 manifest; use rebuild to recover metadata")
            }
            return
        }
        let emitStatus: @Sendable (String) -> Void = if statusToStderr {
            { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        } else {
            { print($0) }
        }

        let migrationGuard = MigrationGuard(
            loadManifest: {
                let (_, _, manifestStore) = try makeBackupDeps(profile: profile)
                return try await loadManifest(store: manifestStore)
            },
            makeRunner: { progress in try await makeMigrationRunner(progress: progress, profile: profile) },
            isTTY: isatty(STDOUT_FILENO) != 0 && isatty(STDIN_FILENO) != 0,
            readAnswer: { readLine() },
            emitPrompt: { FileHandle.standardError.write(Data($0.utf8)) },
            emitStatus: emitStatus,
        )
        try await migrationGuard.ensureMigrated()
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
