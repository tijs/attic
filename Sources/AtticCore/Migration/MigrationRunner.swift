import Foundation
import LadderKit

/// Aggregated outcome of a full migration run, surfaced to the CLI for
/// user-visible reporting.
public struct MigrationReport: Sendable {
    public var alreadyMigrated: Bool
    public var cloudMigrated: Int
    public var localFallback: Int
    public var multipleFoundCollisions: [String]
    public var rekeyCollisions: [String]
    public var errors: [String: String]
    public var unmapped: [String]
    public var metadataRewritten: Int
    public var metadataMissing: Int
    public var totalEntries: Int

    public init(
        alreadyMigrated: Bool = false,
        cloudMigrated: Int = 0,
        localFallback: Int = 0,
        multipleFoundCollisions: [String] = [],
        rekeyCollisions: [String] = [],
        errors: [String: String] = [:],
        unmapped: [String] = [],
        metadataRewritten: Int = 0,
        metadataMissing: Int = 0,
        totalEntries: Int = 0,
    ) {
        self.alreadyMigrated = alreadyMigrated
        self.cloudMigrated = cloudMigrated
        self.localFallback = localFallback
        self.multipleFoundCollisions = multipleFoundCollisions
        self.rekeyCollisions = rekeyCollisions
        self.errors = errors
        self.unmapped = unmapped
        self.metadataRewritten = metadataRewritten
        self.metadataMissing = metadataMissing
        self.totalEntries = totalEntries
    }
}

public enum MigrationError: Error, CustomStringConvertible {
    case manifestEntryCountMismatch(v1: Int, v2: Int)
    case missingMetadataJSON(uuid: String, key: String)

    public var description: String {
        switch self {
        case let .manifestEntryCountMismatch(v1, v2):
            "Migration validation failed: v1 manifest had \(v1) entries, v2 has \(v2). Refusing to swap."
        case let .missingMetadataJSON(uuid, key):
            "Metadata JSON \(key) for uuid \(uuid) could not be parsed during migration."
        }
    }
}

/// Orchestrates a v1 → v2 cloud-identity migration on an attic backup.
///
/// Steps are individually idempotent so re-running after an interruption
/// completes the migration without data loss. The last write is the
/// `manifest.json` swap, so a partial run leaves the canonical manifest
/// as v1 and subsequent commands see "still v1".
public struct MigrationRunner: Sendable {
    public typealias ProgressHandler = @Sendable (String) -> Void

    private let s3: any S3Providing
    private let manifestStore: any ManifestStoring
    private let resolver: any CloudIdentityResolving
    private let assetIdentifierProvider: @Sendable () -> [(bareUUID: String, fullLocalIdentifier: String)]
    private let retryStore: any RetryQueueProviding
    private let unavailableStore: any UnavailableAssetStoring
    private let progress: ProgressHandler?

    public init(
        s3: any S3Providing,
        manifestStore: any ManifestStoring,
        resolver: any CloudIdentityResolving,
        assetIdentifierProvider: @escaping @Sendable () -> [(bareUUID: String, fullLocalIdentifier: String)],
        retryStore: any RetryQueueProviding,
        unavailableStore: any UnavailableAssetStoring,
        progress: ProgressHandler? = nil,
    ) {
        self.s3 = s3
        self.manifestStore = manifestStore
        self.resolver = resolver
        self.assetIdentifierProvider = assetIdentifierProvider
        self.retryStore = retryStore
        self.unavailableStore = unavailableStore
        self.progress = progress
    }

    /// Whether the manifest at `manifestS3Key` is already v2. Cheap probe —
    /// CLI gate calls this before deciding to prompt the user.
    public func detectIsV1() async throws -> Bool {
        let manifest = try await manifestStore.load()
        return manifest.isV1
    }

    /// Run the migration. Returns a report on success. Throws on validation
    /// failure or unrecoverable I/O error; partial state is safe to re-run.
    public func run(dryRun: Bool = false) async throws -> MigrationReport {
        progress?("Loading manifest from S3…")
        let v1 = try await manifestStore.load()
        if !v1.isV1 {
            progress?("Manifest is already v2 — nothing to migrate.")
            return MigrationReport(alreadyMigrated: true, totalEntries: v1.entries.count)
        }

        progress?("Snapshotting v1 manifest as manifest.v1.json (idempotent)…")
        if !dryRun {
            try await snapshotV1IfMissing(v1)
        }

        progress?("Resolving cloud identifiers for \(v1.entries.count) entries…")
        let mapping = await buildMapping(forManifestKeys: Set(v1.entries.keys))

        progress?("Computing v2 manifest in memory…")
        let (v2, manifestResult) = migrateManifestToV2(v1, mapping: mapping)

        guard v2.entries.count == v1.entries.count - manifestResult.rekeyCollisions.count else {
            throw MigrationError.manifestEntryCountMismatch(v1: v1.entries.count, v2: v2.entries.count)
        }

        if dryRun {
            progress?("Dry run — skipping S3 writes.")
            return makeReport(manifestResult, metadataRewritten: 0, metadataMissing: 0, totalEntries: v1.entries.count)
        }

        progress?("Writing staged manifest.v2.json…")
        try await s3.putObject(
            key: manifestV2StagingS3Key,
            body: try v2.encoded(),
            contentType: "application/json",
        )

        progress?("Rewriting per-asset metadata JSONs for cloud-migrated entries…")
        let (rewritten, missing) = try await rewriteMetadataJSONs(
            v1: v1,
            v2: v2,
            mapping: mapping,
        )

        progress?("Migrating retry queue…")
        try migrateLocalRetryQueue(mapping: mapping)

        progress?("Migrating unavailable-asset store…")
        try migrateLocalUnavailableStore(mapping: mapping)

        progress?("Swapping manifest.json to v2 atomically…")
        try await manifestStore.save(v2)

        progress?("Cleaning up staging key…")
        try? await s3.deleteObject(key: manifestV2StagingS3Key)

        progress?("Migration complete.")
        return makeReport(
            manifestResult,
            metadataRewritten: rewritten,
            metadataMissing: missing,
            totalEntries: v1.entries.count,
        )
    }

    // MARK: - Private steps

    private func snapshotV1IfMissing(_ v1: Manifest) async throws {
        if try await s3.headObject(key: manifestV1BackupS3Key) != nil {
            return
        }
        try await s3.putObject(
            key: manifestV1BackupS3Key,
            body: try v1.encoded(sortedKeys: true),
            contentType: "application/json",
        )
    }

    private func buildMapping(forManifestKeys manifestKeys: Set<String>) async -> [String: CloudMappingResult] {
        // Build [bareUuid: fullLocalIdentifier]. Library asset UUIDs that are
        // not present in the manifest are skipped — saves a no-op resolver
        // call on a freshly-imported library.
        let library = assetIdentifierProvider()
        var fullLocalByBare: [String: String] = [:]
        for entry in library where manifestKeys.contains(entry.bareUUID) {
            fullLocalByBare[entry.bareUUID] = entry.fullLocalIdentifier
        }

        guard !fullLocalByBare.isEmpty else { return [:] }

        let fullIds = Array(fullLocalByBare.values)
        let raw = await resolver.resolve(localIdentifiers: fullIds)

        // Translate back to bare-uuid keyed map.
        var byBareUuid: [String: CloudMappingResult] = [:]
        let bareByFullId = Dictionary(uniqueKeysWithValues: fullLocalByBare.map { ($0.value, $0.key) })
        for (fullId, mapping) in raw {
            if let bare = bareByFullId[fullId] {
                byBareUuid[bare] = mapping
            }
        }
        return byBareUuid
    }

    private func rewriteMetadataJSONs(
        v1: Manifest,
        v2: Manifest,
        mapping: [String: CloudMappingResult],
    ) async throws -> (rewritten: Int, missing: Int) {
        var rewritten = 0
        var missing = 0

        // Iterate over v1 entries to find which keys actually need rewriting.
        for (oldUuid, _) in v1.entries {
            guard case .cloud(let cloudId) = mapping[oldUuid] else { continue }
            // Skip if v2 manifest doesn't have this cloud id (a collision
            // dropped it on rekey).
            guard v2.entries[cloudId] != nil else { continue }

            let oldKey = "metadata/assets/\(oldUuid).json"
            let newKey = "metadata/assets/\(cloudId).json"

            if try await s3.headObject(key: newKey) != nil {
                // Already migrated on a prior partial run.
                continue
            }

            let oldData: Data
            do {
                oldData = try await s3.getObject(key: oldKey)
            } catch {
                // Old metadata JSON was never uploaded (or already deleted by
                // prior partial run). Soft-skip rather than fail migration.
                missing += 1
                continue
            }

            let updated = try rewriteMetadataPayload(
                oldData,
                cloudUUID: cloudId,
                legacyLocalIdentifier: oldUuid,
            )

            try await s3.putObject(
                key: newKey,
                body: updated,
                contentType: "application/json",
            )
            try? await s3.deleteObject(key: oldKey)
            rewritten += 1
        }

        return (rewritten, missing)
    }

    private func rewriteMetadataPayload(
        _ data: Data,
        cloudUUID: String,
        legacyLocalIdentifier: String,
    ) throws -> Data {
        var meta = try JSONDecoder().decode(AssetMetadata.self, from: data)
        meta.uuid = cloudUUID
        meta.legacyLocalIdentifier = legacyLocalIdentifier
        meta.identityKind = .cloud
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(meta)
    }

    private func migrateLocalRetryQueue(mapping: [String: CloudMappingResult]) throws {
        guard let queue = retryStore.load() else { return }
        let (migrated, _) = migrateRetryQueueToV2(queue, mapping: mapping)
        try retryStore.save(migrated)
    }

    private func migrateLocalUnavailableStore(mapping: [String: CloudMappingResult]) throws {
        let store = unavailableStore.load()
        guard !store.entries.isEmpty else { return }
        let (migrated, _) = migrateUnavailableStoreToV2(store, mapping: mapping)
        try unavailableStore.save(migrated)
    }

    private func makeReport(
        _ result: MigrationResult,
        metadataRewritten: Int,
        metadataMissing: Int,
        totalEntries: Int,
    ) -> MigrationReport {
        MigrationReport(
            alreadyMigrated: false,
            cloudMigrated: result.cloudMigrated,
            localFallback: result.localFallback,
            multipleFoundCollisions: result.multipleFoundCollisions,
            rekeyCollisions: result.rekeyCollisions,
            errors: result.errors,
            unmapped: result.unmapped,
            metadataRewritten: metadataRewritten,
            metadataMissing: metadataMissing,
            totalEntries: totalEntries,
        )
    }
}
