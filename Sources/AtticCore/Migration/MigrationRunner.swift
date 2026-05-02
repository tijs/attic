import Foundation
import LadderKit

/// Format a ``MigrationReport`` as a single JSON object. Stable schema for
/// agent / CI consumption: keys never disappear, counters always present
/// (zero when the category did not fire), arrays empty when no entries.
public func formatMigrationReportJSON(_ report: MigrationReport, dryRun: Bool) throws -> Data {
    var json: [String: Any] = [
        "alreadyMigrated": report.alreadyMigrated,
        "dryRun": dryRun,
        "totalEntries": report.totalEntries,
        "cloudMigrated": report.cloudMigrated,
        "localFallback": report.localFallback,
        "metadataRewritten": report.metadataRewritten,
        "metadataMissing": report.metadataMissing,
        "rekeyCollisions": report.rekeyCollisions,
        "multipleFoundCollisions": report.multipleFoundCollisions,
        "unmapped": report.unmapped,
    ]
    var errs: [[String: String]] = []
    for (uuid, message) in report.errors {
        errs.append(["uuid": uuid, "message": message])
    }
    json["errors"] = errs
    return try JSONSerialization.data(
        withJSONObject: json,
        options: [.prettyPrinted, .sortedKeys],
    )
}

/// Format a ``MigrationReport`` as a human-readable, multi-line string for
/// CLI display. Pure: no I/O — caller writes to stdout.
public func formatMigrationReport(_ report: MigrationReport, dryRun: Bool) -> String {
    if report.alreadyMigrated {
        return "Manifest is already v2.\n"
    }
    var out = "──────────────────────────────────────\n"
    out += "Migration report\(dryRun ? " (dry run)" : "")\n"
    out += "  Total entries          \(report.totalEntries)\n"
    out += "  Re-keyed to cloud id   \(report.cloudMigrated)\n"
    out += "  Local fallback         \(report.localFallback)\n"
    if !report.unmapped.isEmpty {
        out += "  Unmapped (deleted?)    \(report.unmapped.count)\n"
    }
    if !report.multipleFoundCollisions.isEmpty {
        out += "  Multiple-found        \(report.multipleFoundCollisions.count) (review manually)\n"
    }
    if !report.rekeyCollisions.isEmpty {
        out += "  Re-key collisions     \(report.rekeyCollisions.count)\n"
    }
    if !report.errors.isEmpty {
        out += "  Transient errors       \(report.errors.count) (re-run to retry)\n"
    }
    if !dryRun {
        out += "  Metadata JSONs rewritten  \(report.metadataRewritten)\n"
        if report.metadataMissing > 0 {
            out += "  Metadata JSONs missing    \(report.metadataMissing)\n"
        }
    }
    out += "\n"
    return out
}

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
    case zeroCloudMappingsResolved(manifestEntries: Int, attempted: Int)
    case tooManyUnmapped(localFallback: Int, cloudMigrated: Int, threshold: Double)

    public var description: String {
        switch self {
        case let .manifestEntryCountMismatch(v1, v2):
            "Migration validation failed: v1 manifest had \(v1) entries, v2 has \(v2). Refusing to swap."
        case let .missingMetadataJSON(uuid, key):
            "Metadata JSON \(key) for uuid \(uuid) could not be parsed during migration."
        case let .zeroCloudMappingsResolved(entries, attempted):
            """
            Migration aborted — manifest left untouched. PhotoKit returned 0 cloud \
            identifiers for any of the \(attempted) assets attempted (\(entries) \
            entries in the manifest).

            The most likely cause is that this is not the Mac that originally \
            produced the backup. PhotoKit local IDs are per-device, so a Mac \
            that didn't write the v1 manifest can't translate its keys to cloud \
            IDs. Run `attic migrate` on the original Mac, then any Mac in the \
            same iCloud Photos library can use the backup.

            Other possible causes: iCloud Photos disabled, PhotoKit access not \
            granted, or the Photos library is signed into a different iCloud \
            account. If you have verified all of these and still see this, \
            re-run with `attic migrate --force`.
            """
        case let .tooManyUnmapped(local, cloud, threshold):
            """
            Migration aborted — manifest left untouched. \(local) of \
            \(local + cloud) entries failed cloud resolution (>= \
            \(Int(threshold * 100))% threshold).

            Likely cause: this is not the Mac that originally produced the \
            backup, or PhotoKit / iCloud Photos is not fully set up here. \
            Run `attic migrate` on the original Mac, or verify iCloud Photos \
            is enabled and PhotoKit access is granted. Pass `--force` to \
            accept the partial mapping (most entries will keep device-local \
            keys and won't be recognized cross-device).
            """
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
    private let lock: MigrationLock
    private let unmappedFailureThreshold: Double
    private let progress: ProgressHandler?

    public init(
        s3: any S3Providing,
        manifestStore: any ManifestStoring,
        resolver: any CloudIdentityResolving,
        assetIdentifierProvider: @escaping @Sendable () -> [(bareUUID: String, fullLocalIdentifier: String)],
        retryStore: any RetryQueueProviding,
        unavailableStore: any UnavailableAssetStoring,
        lock: MigrationLock? = nil,
        unmappedFailureThreshold: Double = 0.95,
        progress: ProgressHandler? = nil,
    ) {
        self.s3 = s3
        self.manifestStore = manifestStore
        self.resolver = resolver
        self.assetIdentifierProvider = assetIdentifierProvider
        self.retryStore = retryStore
        self.unavailableStore = unavailableStore
        self.lock = lock ?? MigrationLock(s3: s3)
        self.unmappedFailureThreshold = unmappedFailureThreshold
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
    ///
    /// - Parameter dryRun: Plan only — no S3 writes.
    /// - Parameter force: Bypass the cloud-resolution anomaly check. Use only
    ///   when you have manually verified iCloud Photos is enabled and PhotoKit
    ///   access is granted, but a previous run still tripped the safety guard.
    public func run(dryRun: Bool = false, force: Bool = false) async throws -> MigrationReport {
        progress?("Loading manifest from S3…")
        let v1 = try await manifestStore.load()
        if !v1.isV1 {
            progress?("Manifest is already v2 — nothing to migrate.")
            return MigrationReport(alreadyMigrated: true, totalEntries: v1.entries.count)
        }

        // Acquire the cross-machine lock before any v2 writes. Skipped on
        // dry-run since dry-run never mutates S3.
        var acquiredLock = false
        if !dryRun {
            _ = try await lock.acquire()
            acquiredLock = true
        }
        defer {
            if acquiredLock {
                Task { await lock.release() }
            }
        }

        progress?("Snapshotting v1 manifest as manifest.v1.json (idempotent)…")
        if !dryRun {
            try await snapshotV1IfMissing(v1)
        }

        progress?("Resolving cloud identifiers for \(v1.entries.count) entries…")
        let mapping = await buildMapping(forManifestKeys: Set(v1.entries.keys))

        // Anomaly guard: if the resolver returned ZERO cloud mappings while
        // a meaningful share of v1 entries are present, something went wrong
        // (PhotoKit consent revoked, iCloud Photos disabled, library not
        // signed in). Stamping every entry as `.local` and bumping the
        // manifest to v2 would silently lock the user out of cross-device
        // recognition with no recovery path. Bail loudly instead.
        let cloudCount = mapping.values.reduce(0) { acc, r in
            if case .cloud = r { return acc + 1 }
            return acc
        }
        if !force, !v1.entries.isEmpty, cloudCount == 0 {
            throw MigrationError.zeroCloudMappingsResolved(
                manifestEntries: v1.entries.count,
                attempted: mapping.count,
            )
        }

        progress?("Computing v2 manifest in memory…")
        let (v2, manifestResult) = migrateManifestToV2(v1, mapping: mapping)

        guard v2.entries.count == v1.entries.count - manifestResult.rekeyCollisions.count else {
            throw MigrationError.manifestEntryCountMismatch(v1: v1.entries.count, v2: v2.entries.count)
        }

        // Secondary anomaly guard: if a non-trivial share of v1 entries fell
        // back to `.local` (above the configured threshold) and force is
        // false, refuse the swap. This catches the case where PhotoKit
        // returned mappings for *some* assets but the resolver was clearly
        // unhealthy for the rest.
        if !force, !v1.entries.isEmpty {
            let unmappedShare = Double(manifestResult.localFallback) / Double(v1.entries.count)
            if unmappedShare >= unmappedFailureThreshold, manifestResult.cloudMigrated > 0 {
                throw MigrationError.tooManyUnmapped(
                    localFallback: manifestResult.localFallback,
                    cloudMigrated: manifestResult.cloudMigrated,
                    threshold: unmappedFailureThreshold,
                )
            }
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
            v2: v2,
            losers: manifestResult.rekeyCollisions,
        )

        progress?("Swapping manifest.json to v2 atomically…")
        try await manifestStore.save(v2)

        // Local store mutations only AFTER successful S3 swap. If the swap
        // fails, the local files keep their v1 keys, matching the canonical
        // v1 manifest still on S3. Re-running the migration finds v1 again
        // and re-keys cleanly. If a local-store save fails after the swap,
        // the next command sees v2 on S3 and the runner short-circuits — at
        // worst, the local store keeps v1 keys and earns one more retry on
        // its next save.
        progress?("Migrating retry queue…")
        try migrateLocalRetryQueue(mapping: mapping)

        progress?("Migrating unavailable-asset store…")
        try migrateLocalUnavailableStore(mapping: mapping)

        progress?("Cleaning up staging key…")
        do {
            try await s3.deleteObject(key: manifestV2StagingS3Key)
        } catch {
            progress?("Warning: could not delete staging key \(manifestV2StagingS3Key): \(error). " +
                "Run `attic migrate --repair` to clean up.")
        }

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

    /// Rewrite per-asset metadata JSONs to match v2 manifest entries.
    ///
    /// Drives from the v2 manifest (single source of truth post-migration):
    /// each `.cloud` entry's `legacyLocalIdentifier` is the *winner* old uuid
    /// — the one whose metadata payload should be preserved at the new key.
    /// Loser uuids from re-key collisions are deleted separately so their
    /// payloads cannot overwrite the winner.
    private func rewriteMetadataJSONs(
        v2: Manifest,
        losers: [String],
    ) async throws -> (rewritten: Int, missing: Int) {
        var rewritten = 0
        var missing = 0

        // Step 1: drop loser metadata keys first so a re-write of a winner
        // sharing none of the loser's bytes cannot accidentally overwrite.
        // Failures are logged but non-fatal — the orphan can be cleaned up
        // by a future `attic verify --reconcile` pass.
        for loser in losers {
            let oldKey = try S3Paths.metadataKey(uuid: loser)
            do {
                try await s3.deleteObject(key: oldKey)
            } catch {
                progress?("Warning: could not delete loser metadata key \(oldKey): \(error)")
            }
        }

        // Step 2: for each v2 cloud entry, copy its winner-old metadata to
        // the new cloud-keyed location. Idempotent — skip if already done.
        for (cloudId, entry) in v2.entries {
            guard entry.identityKind == .cloud,
                  let legacy = entry.legacyLocalIdentifier,
                  legacy != cloudId
            else { continue }

            let oldKey = try S3Paths.metadataKey(uuid: legacy)
            let newKey = try S3Paths.metadataKey(uuid: cloudId)

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
                legacyLocalIdentifier: legacy,
            )

            try await s3.putObject(
                key: newKey,
                body: updated,
                contentType: "application/json",
            )
            do {
                try await s3.deleteObject(key: oldKey)
            } catch {
                progress?("Warning: could not delete migrated metadata key \(oldKey): \(error)")
            }
            rewritten += 1
        }

        return (rewritten, missing)
    }

    /// Rewrite identity fields on a metadata JSON payload while preserving
    /// any unknown / future / Deno-written keys verbatim. Decoding through
    /// `AssetMetadata` would silently strip those, which is destructive when
    /// the same backup is also accessed by tools that produce extra fields.
    func rewriteMetadataPayload(
        _ data: Data,
        cloudUUID: String,
        legacyLocalIdentifier: String,
    ) throws -> Data {
        guard
            var json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw MigrationError.missingMetadataJSON(uuid: cloudUUID, key: legacyLocalIdentifier)
        }
        json["uuid"] = cloudUUID
        json["legacyLocalIdentifier"] = legacyLocalIdentifier
        json["identityKind"] = IdentityKind.cloud.rawValue
        return try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys],
        )
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
