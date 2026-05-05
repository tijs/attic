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
        "thumbnailsDeleted": report.thumbnailsDeleted,
        "thumbnailsBytes": report.thumbnailsBytes,
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
    /// Number of orphaned `thumbnails/` keys deleted (or, in dry-run, the
    /// count that would be deleted). Zero when the cleanup phase did not run.
    public var thumbnailsDeleted: Int
    /// Total size in bytes of thumbnails deleted (or planned for deletion in
    /// dry-run). Zero when the cleanup phase did not run.
    public var thumbnailsBytes: Int64

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
        thumbnailsDeleted: Int = 0,
        thumbnailsBytes: Int64 = 0,
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
        self.thumbnailsDeleted = thumbnailsDeleted
        self.thumbnailsBytes = thumbnailsBytes
    }
}

/// Decision returned by the cleanup-confirmation handler. Lifted out of
/// `MigrationPrompt.Decision` because the cleanup prompt is a separate
/// surface — different copy, different runtime estimate, different runtime
/// error path on non-interactive abort.
public enum CleanupConfirmation: Sendable, Equatable {
    case proceed
    case abort
    case nonInteractive
}

/// Errors thrown by the runner specific to the thumbnail-cleanup phase.
/// `MigrationError` is reserved for v1→v2 validation failures; cleanup
/// phase failures get their own enum so the gate can translate them
/// distinctly without a stringly-typed switch.
public enum MigrationRunnerError: Error, CustomStringConvertible {
    /// One or more `deleteObject` calls failed during cleanup. The flag is
    /// not set; re-run completes the remaining keys.
    case thumbnailCleanupPartial(deleted: Int, failed: [String: String])
    /// User declined the cleanup prompt.
    case thumbnailCleanupDeclined
    /// Cleanup was required (non-empty prefix, apply mode) but the caller
    /// signalled a non-interactive context where prompting cannot occur.
    case thumbnailCleanupNonInteractive(count: Int, bytes: Int64)

    public var description: String {
        switch self {
        case let .thumbnailCleanupPartial(deleted, failed):
            "Thumbnail cleanup partially failed: \(deleted) deleted, \(failed.count) failed. Re-run to retry."
        case .thumbnailCleanupDeclined:
            "Thumbnail cleanup declined."
        case let .thumbnailCleanupNonInteractive(count, bytes):
            "Thumbnail cleanup requires interactive confirmation (\(count) objects, \(bytes) bytes)."
        }
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
    /// Closure the gate (or test) provides so the runner can ask whether to
    /// proceed with thumbnail deletion after listing the prefix. Receives
    /// `(count, totalBytes)`; returns the decision.
    public typealias CleanupConfirmHandler = @Sendable (Int, Int64) async -> CleanupConfirmation

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

    /// Result of the cheap manifest probe.
    public struct ManifestProbe: Sendable {
        public let isV1: Bool
        public let entryCount: Int
        public let thumbnailsCleanupApplied: Bool
    }

    /// Whether the manifest at `manifestS3Key` is already v2 plus its current
    /// entry count and cleanup state. Cheap probe — CLI gate calls this
    /// before deciding to prompt the user, and uses `entryCount` to size the
    /// runtime estimate without issuing a second S3 GET. The
    /// `thumbnailsCleanupApplied` flag lets the gate fast-path away from
    /// `runner.run()` entirely when both phases are already done.
    public func probeManifest() async throws -> ManifestProbe {
        let manifest = try await manifestStore.load()
        return ManifestProbe(
            isV1: manifest.isV1,
            entryCount: manifest.entries.count,
            thumbnailsCleanupApplied: manifest.thumbnailsCleanupApplied,
        )
    }

    /// Convenience wrapper for callers that only need the v1 flag. Prefer
    /// ``probeManifest()`` when the entry count is also needed.
    public func detectIsV1() async throws -> Bool {
        try await probeManifest().isV1
    }

    /// Run the migration. Returns a report on success. Throws on validation
    /// failure or unrecoverable I/O error; partial state is safe to re-run.
    ///
    /// - Parameter dryRun: Plan only — no S3 writes.
    /// - Parameter force: Bypass the cloud-resolution anomaly check. Use only
    ///   when you have manually verified iCloud Photos is enabled and PhotoKit
    ///   access is granted, but a previous run still tripped the safety guard.
    /// - Parameter confirmCleanup: Called when the cleanup phase finds
    ///   non-empty `thumbnails/` and is about to apply. Must return
    ///   `.proceed` to delete, `.abort` to skip with a declined error, or
    ///   `.nonInteractive` to surface a non-TTY error to the gate. Defaults
    ///   to a closure that returns `.proceed` (suitable for tests; the gate
    ///   wires a real prompt).
    public func run(
        dryRun: Bool = false,
        force: Bool = false,
        confirmCleanup: CleanupConfirmHandler = { _, _ in .proceed },
    ) async throws -> MigrationReport {
        progress?("Loading manifest from S3…")
        var manifest = try await manifestStore.load()

        let needsV1 = manifest.isV1
        let needsCleanup = !manifest.thumbnailsCleanupApplied
        if !needsV1, !needsCleanup {
            progress?("Manifest is already v2 and thumbnails cleanup applied — nothing to migrate.")
            return MigrationReport(alreadyMigrated: true, totalEntries: manifest.entries.count)
        }

        // Acquire the cross-machine lock before any v2 writes — covers both
        // the v1→v2 phase and the cleanup phase. Skipped on dry-run since
        // dry-run never mutates S3.
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

        var report: MigrationReport
        if needsV1 {
            report = try await runV1ToV2Phase(v1: manifest, dryRun: dryRun, force: force)
            // Reload the manifest after the v1→v2 swap so the cleanup phase
            // sees the freshly-saved v2 (with `thumbnailsCleanupApplied` at
            // its default `false`).
            if !dryRun {
                manifest = try await manifestStore.load()
            }
        } else {
            report = MigrationReport(totalEntries: manifest.entries.count)
        }

        // Cleanup phase — runs whenever the v2 manifest's flag is false,
        // including immediately after a successful v1→v2 swap in this same
        // invocation.
        if !manifest.thumbnailsCleanupApplied {
            let cleanup = try await runThumbnailCleanupPhase(
                manifest: manifest,
                dryRun: dryRun,
                confirmCleanup: confirmCleanup,
            )
            report.thumbnailsDeleted = cleanup.deleted
            report.thumbnailsBytes = cleanup.bytes
        }

        return report
    }

    /// v1 → v2 migration phase, extracted from the original monolithic
    /// `run()` body so the cleanup phase can compose on top.
    private func runV1ToV2Phase(
        v1: Manifest,
        dryRun: Bool,
        force: Bool,
    ) async throws -> MigrationReport {
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
            body: v2.encoded(),
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

    /// Cleanup phase. Lists `thumbnails/`; on empty, sets the flag silently
    /// and saves. On non-empty, asks the caller via `confirmCleanup`. On
    /// `.proceed`, runs `runThumbnailCleanup` and atomically flips the flag
    /// only after a clean delete + a successful manifest save.
    private func runThumbnailCleanupPhase(
        manifest: Manifest,
        dryRun: Bool,
        confirmCleanup: CleanupConfirmHandler,
    ) async throws -> ThumbnailCleanupResult {
        progress?("Probing thumbnails/ prefix…")
        // Probe by counting + summing bytes via a dry-run pass. The runner
        // collects the same listing it would otherwise drive deletes from,
        // so the prompt has accurate counts.
        let probe = try await runThumbnailCleanup(
            s3: s3,
            dryRun: true,
            progress: { _, _ in },
        )

        if probe.deleted == 0 {
            // Empty prefix — silent set + save (R3). Skip on dry-run since
            // dry-run never mutates S3.
            if !dryRun {
                progress?("Empty thumbnails/ prefix — recording cleanup applied.")
                var updated = manifest
                updated.thumbnailsCleanupApplied = true
                try await manifestStore.save(updated)
            } else {
                progress?("Empty thumbnails/ prefix — would record cleanup applied.")
            }
            return ThumbnailCleanupResult(deleted: 0, bytes: 0, failed: [:])
        }

        if dryRun {
            progress?("Dry run — would delete \(probe.deleted) thumbnails (\(probe.bytes) bytes).")
            return probe
        }

        let confirmation = await confirmCleanup(probe.deleted, probe.bytes)
        switch confirmation {
        case .proceed:
            break
        case .abort:
            throw MigrationRunnerError.thumbnailCleanupDeclined
        case .nonInteractive:
            throw MigrationRunnerError.thumbnailCleanupNonInteractive(
                count: probe.deleted,
                bytes: probe.bytes,
            )
        }

        progress?("Deleting \(probe.deleted) thumbnails…")
        let result = try await runThumbnailCleanup(
            s3: s3,
            dryRun: false,
            progress: { [progress] deleted, total in
                progress?("Deleted \(deleted)/\(total) thumbnails…")
            },
        )

        if !result.failed.isEmpty {
            // Leave the flag false; throw a structured error so the gate
            // surfaces a non-zero exit and the user knows to re-run.
            throw MigrationRunnerError.thumbnailCleanupPartial(
                deleted: result.deleted,
                failed: result.failed,
            )
        }

        // Atomicity: flip the flag only after every delete returned success.
        // Re-load to avoid clobbering any concurrent manifest writes (none
        // expected — the lock prevents that — but cheap and explicit).
        var updated = try await manifestStore.load()
        updated.thumbnailsCleanupApplied = true
        try await manifestStore.save(updated)

        return result
    }

    // MARK: - Private steps

    private func snapshotV1IfMissing(_ v1: Manifest) async throws {
        if try await s3.headObject(key: manifestV1BackupS3Key) != nil {
            return
        }
        try await s3.putObject(
            key: manifestV1BackupS3Key,
            body: v1.encoded(sortedKeys: true),
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
        concurrency: Int = 16,
    ) async throws -> (rewritten: Int, missing: Int) {
        // Step 1: drop loser metadata keys first so a re-write of a winner
        // sharing none of the loser's bytes cannot accidentally overwrite.
        // Failures are logged but non-fatal — the orphan can be cleaned up
        // by a future `attic verify --reconcile` pass.
        await withTaskGroup(of: Void.self) { group in
            for loser in losers {
                group.addTask {
                    guard let oldKey = try? S3Paths.metadataKey(uuid: loser) else { return }
                    do {
                        try await s3.deleteObject(key: oldKey)
                    } catch {
                        progress?("Warning: could not delete loser metadata key \(oldKey): \(error)")
                    }
                }
            }
        }

        // Step 2: collect rewrite-eligible v2 entries. Each one is independent —
        // HEAD probe, GET old, PUT new, DELETE old per asset. Serial loops at
        // ~100ms RTT × 4 ops × 27k assets push runtime to multiple hours; a
        // bounded task group gets that down to ~10–15 minutes on the same link.
        let candidates: [(cloudId: String, legacy: String)] = v2.entries.compactMap { cloudId, entry in
            guard entry.identityKind == .cloud,
                  let legacy = entry.legacyLocalIdentifier,
                  legacy != cloudId
            else { return nil }
            return (cloudId, legacy)
        }

        let counter = RewriteCounter()
        let total = candidates.count

        try await withThrowingTaskGroup(of: Void.self) { group in
            var cursor = 0
            let initial = min(concurrency, candidates.count)
            for _ in 0 ..< initial {
                let candidate = candidates[cursor]
                cursor += 1
                group.addTask { try await rewriteSingle(candidate, counter: counter, total: total) }
            }
            while try await group.next() != nil {
                if cursor < candidates.count {
                    let candidate = candidates[cursor]
                    cursor += 1
                    group.addTask { try await rewriteSingle(candidate, counter: counter, total: total) }
                }
            }
        }

        return await (counter.rewrittenCount, counter.missingCount)
    }

    private func rewriteSingle(
        _ candidate: (cloudId: String, legacy: String),
        counter: RewriteCounter,
        total: Int,
    ) async throws {
        let oldKey = try S3Paths.metadataKey(uuid: candidate.legacy)
        let newKey = try S3Paths.metadataKey(uuid: candidate.cloudId)

        if try await s3.headObject(key: newKey) != nil {
            // Already migrated on a prior partial run.
            return
        }

        let oldData: Data
        do {
            oldData = try await s3.getObject(key: oldKey)
        } catch {
            // Old metadata JSON was never uploaded (or already deleted by
            // prior partial run). Soft-skip rather than fail migration.
            await counter.incMissing()
            return
        }

        let updated = try rewriteMetadataPayload(
            oldData,
            cloudUUID: candidate.cloudId,
            legacyLocalIdentifier: candidate.legacy,
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
        let n = await counter.incRewritten()
        if n % 250 == 0 || n == total {
            progress?("Rewrote \(n)/\(total) metadata JSONs…")
        }
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

/// Thread-safe counter for parallel metadata-JSON rewrites. Returning the
/// post-increment count lets callers emit periodic progress without a second
/// load.
private actor RewriteCounter {
    private(set) var rewrittenCount = 0
    private(set) var missingCount = 0

    func incRewritten() -> Int {
        rewrittenCount += 1
        return rewrittenCount
    }

    func incMissing() {
        missingCount += 1
    }
}
