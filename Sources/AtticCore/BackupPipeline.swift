import Foundation
import LadderKit

/// Options controlling backup behavior.
public struct BackupOptions: Sendable {
    public var batchSize: Int
    public var limit: Int
    public var type: AssetKind?
    public var dryRun: Bool
    public var concurrency: Int
    public var networkTimeout: Duration
    public var maxPauseRetries: Int
    public var stagingDir: URL?

    public init(
        batchSize: Int = 10,
        limit: Int = 0,
        type: AssetKind? = nil,
        dryRun: Bool = false,
        concurrency: Int = 6,
        networkTimeout: Duration = .seconds(900),
        maxPauseRetries: Int = 3,
        stagingDir: URL? = nil,
    ) {
        self.batchSize = batchSize
        self.limit = limit
        self.type = type
        self.dryRun = dryRun
        self.concurrency = concurrency
        self.networkTimeout = networkTimeout
        self.maxPauseRetries = maxPauseRetries
        self.stagingDir = stagingDir
    }
}

/// Cap on stored error detail to prevent unbounded report growth on very
/// large runs with many failures.
let maxReportErrors = 1000

/// Result of a backup run.
public struct BackupReport: Sendable {
    public var uploaded: Int = 0
    public var failed: Int = 0
    public var skipped: Int = 0
    public var totalBytes: Int = 0
    public var errors: [(uuid: String, message: String)] = []

    mutating func appendError(uuid: String, message: String) {
        if errors.count < maxReportErrors {
            errors.append((uuid: uuid, message: message))
        }
    }
}

/// Filter `assets` to what this run should attempt: pending (not backed up,
/// not known-unavailable), optionally restricted by type, limited to
/// `options.limit`, with retry-queue UUIDs partitioned to the front.
func filterPending(
    assets: [AssetInfo],
    manifest: Manifest,
    unavailable: UnavailableAssets,
    retryQueue: RetryQueue?,
    options: BackupOptions,
) -> [AssetInfo] {
    var pending = assets.filter { asset in
        if manifest.isBackedUp(asset.uuid) { return false }
        if unavailable.contains(asset.uuid) { return false }
        if let type = options.type, asset.kind != type { return false }
        return true
    }

    if let retryUUIDs = retryQueue?.failedUUIDs {
        let retrySet = Set(retryUUIDs)
        _ = pending.partition { !retrySet.contains($0.uuid) }
    }

    if options.limit > 0 {
        pending = Array(pending.prefix(options.limit))
    }

    return pending
}

/// Translate an `ExportResult`'s uuid (a PhotoKit local UUID) back to the
/// canonical cloud uuid the rest of the pipeline keys on. Identity passthrough
/// when no mapping exists (e.g. local-fallback assets). Delegates the field
/// preservation to LadderKit's `withUUID(_:)` factory so future
/// `ExportResult` / `ExportError` field additions flow through automatically.
private func remapToCloud(
    _ result: ExportResult,
    using localToCloud: [String: String],
) -> ExportResult {
    result.withUUID(localToCloud[result.uuid] ?? result.uuid)
}

private func remapToCloud(
    _ err: LadderKit.ExportError,
    using localToCloud: [String: String],
) -> LadderKit.ExportError {
    err.withUUID(localToCloud[err.uuid] ?? err.uuid)
}

/// PhotoKit local UUIDs the exporter / AppleScript fallback can fetch by,
/// paired with the cloud-uuid map the rest of the pipeline (manifest,
/// retry queue, S3 keys, error reports) is keyed on. The two fields
/// always travel together — a stale `localToCloud` cannot translate
/// `localIds` correctly.
struct ExportBatchKeys {
    let localIds: [String]
    let localToCloud: [String: String]
}

/// Export a batch. On batch timeout, fall back to per-asset exports and
/// track UUIDs that still time out in `deferred` for a final retry pass.
/// Returns the combined response (reclaimed + freshly exported).
func exportBatchWithFallback(
    keys: ExportBatchKeys,
    reclaimed: [ExportResult],
    exporter: any ExportProviding,
    deferred: inout [String],
    assetByUUID: [String: AssetInfo],
    report: inout BackupReport,
    progress: any BackupProgressDelegate,
) async throws -> ExportResponse {
    if keys.localIds.isEmpty {
        return ExportResponse(results: reclaimed, errors: [])
    }

    do {
        let exported = try await exporter.exportBatch(uuids: keys.localIds)
        return ExportResponse(
            results: reclaimed + exported.results.map { remapToCloud($0, using: keys.localToCloud) },
            errors: exported.errors.map { remapToCloud($0, using: keys.localToCloud) },
        )
    } catch let error as ExportProviderError where error.isTimeout {
        // Batch timeout: retry each asset individually
        var results = reclaimed
        var errors: [LadderKit.ExportError] = []
        for localId in keys.localIds {
            try Task.checkCancellation()
            let cloudUUID = keys.localToCloud[localId] ?? localId
            do {
                let single = try await exporter.exportBatch(uuids: [localId])
                results.append(contentsOf: single.results.map { remapToCloud($0, using: keys.localToCloud) })
                errors.append(contentsOf: single.errors.map { remapToCloud($0, using: keys.localToCloud) })
            } catch let innerError as ExportProviderError where innerError.isTimeout {
                deferred.append(cloudUUID)
            } catch {
                let msg = String(describing: error)
                report.appendError(uuid: cloudUUID, message: msg)
                report.failed += 1
                let filename = assetByUUID[cloudUUID]?.originalFilename ?? cloudUUID
                progress.assetFailed(
                    uuid: cloudUUID,
                    filename: filename,
                    message: msg,
                    classification: .other,
                )
            }
        }
        return ExportResponse(results: results, errors: errors)
    }
}

// swiftlint:disable function_body_length
/// Run the backup pipeline: filter → batch → export → upload → manifest.
public func runBackup(
    assets: [AssetInfo],
    manifest: inout Manifest,
    manifestStore: any ManifestStoring,
    exporter: any ExportProviding,
    s3: any S3Providing,
    options: BackupOptions = BackupOptions(),
    progress: any BackupProgressDelegate = NullProgressDelegate(),
    networkMonitor: (any NetworkMonitoring)? = nil,
    retryQueue: (any RetryQueueProviding)? = nil,
    unavailableStore: (any UnavailableAssetStoring)? = nil,
    adaptiveController: (any AdaptiveConcurrencyControlling)? = nil,
) async throws -> BackupReport {
    var unavailable = unavailableStore?.load() ?? UnavailableAssets()

    let pending = filterPending(
        assets: assets,
        manifest: manifest,
        unavailable: unavailable,
        retryQueue: retryQueue?.load(),
        options: options,
    )

    if pending.isEmpty {
        return BackupReport()
    }

    var photoCount = 0
    var videoCount = 0
    for asset in pending {
        if asset.kind == .photo { photoCount += 1 } else { videoCount += 1 }
    }
    progress.backupStarted(pending: pending.count, photos: photoCount, videos: videoCount)

    if options.dryRun {
        var report = BackupReport()
        report.skipped = pending.count
        return report
    }

    let assetByUUID = Dictionary(uniqueKeysWithValues: pending.map { ($0.uuid, $0) })

    // Cloud uuid (the canonical pipeline key, post-migration) ↔ PhotoKit
    // local uuid (what the exporter / AppleScript fallback can actually
    // fetch). Pre-migration these are identical, but after the v1→v2
    // migration `asset.uuid` is the `PHCloudIdentifier` and the exporter
    // would otherwise reject it as an invalid local identifier.
    //
    // Both directions are derived directly from `pending` (rather than
    // inverting one map into the other) so that a hypothetical local-uuid
    // collision between two cloud-keyed assets is asserted at construction
    // instead of silently last-write-wins'ing a remap into the wrong
    // manifest entry. PhotoKit guarantees per-device local-uuid uniqueness,
    // so the precondition should never fire in practice.
    var cloudToLocal: [String: String] = [:]
    var localToCloud: [String: String] = [:]
    for asset in pending {
        let localId = stripLocalIdSuffix(asset.identifier)
        cloudToLocal[asset.uuid] = localId
        if let existing = localToCloud[localId], existing != asset.uuid {
            preconditionFailure(
                "Two pending assets share the same PhotoKit local UUID '\(localId)' " +
                    "but resolve to different cloud identifiers ('\(existing)', '\(asset.uuid)'). " +
                    "This violates a PhotoKit per-device uniqueness invariant.",
            )
        }
        localToCloud[localId] = asset.uuid
    }

    var report = BackupReport()
    var sinceLastSave = 0
    var deferred: [String] = []
    // Classifications for the subset of failures LadderKit reports. Everything
    // else (upload errors, network timeouts) defaults to `.other` when the
    // retry queue is written.
    var failureClassifications: [String: ExportClassification] = [:]

    let ctx = UploadContext(
        assetByUUID: assetByUUID,
        s3: s3,
        manifestStore: manifestStore,
        concurrency: options.concurrency,
        progress: progress,
        networkMonitor: networkMonitor,
        networkTimeout: options.networkTimeout,
        maxPauseRetries: options.maxPauseRetries,
    )

    func recordFailures(_ errors: [LadderKit.ExportError]) {
        for err in errors {
            failureClassifications[err.uuid] = err.classification
            if err.classification == .permanentlyUnavailable {
                unavailable.record(
                    uuid: err.uuid,
                    filename: assetByUUID[err.uuid]?.originalFilename,
                    reason: err.message,
                )
            }
        }
    }

    let totalBatches = (pending.count + options.batchSize - 1) / options.batchSize

    // Emit the adaptive concurrency limit when it changes between batches.
    var lastEmittedLimit: Int?
    func emitLimitIfChanged() async {
        guard let controller = adaptiveController else { return }
        let limit = await controller.currentLimit()
        if limit != lastEmittedLimit {
            progress.concurrencyChanged(limit: limit)
            lastEmittedLimit = limit
        }
    }
    await emitLimitIfChanged()

    do {
        for batchIndex in 0 ..< totalBatches {
            try Task.checkCancellation()
            await emitLimitIfChanged()

            let start = batchIndex * options.batchSize
            let end = min(start + options.batchSize, pending.count)
            let batch = Array(pending[start ..< end])
            let batchLocalIds = batch.map { cloudToLocal[$0.uuid] ?? $0.uuid }

            progress.batchStarted(
                batchNumber: batchIndex + 1,
                totalBatches: totalBatches,
                assetCount: batch.count,
            )

            var reclaimedResults: [ExportResult] = []
            var localIdsToExport = batchLocalIds
            if let stagingDir = options.stagingDir {
                let reclaim = reclaimStagedFiles(uuids: batchLocalIds, stagingDir: stagingDir)
                reclaimedResults = reclaim.reclaimed.map { remapToCloud($0, using: localToCloud) }
                localIdsToExport = reclaim.remaining
            }

            let batchResult = try await exportBatchWithFallback(
                keys: ExportBatchKeys(localIds: localIdsToExport, localToCloud: localToCloud),
                reclaimed: reclaimedResults,
                exporter: exporter,
                deferred: &deferred,
                assetByUUID: assetByUUID,
                report: &report,
                progress: progress,
            )

            recordFailures(batchResult.errors)

            try await uploadExported(
                batchResult, ctx: ctx,
                manifest: &manifest, report: &report,
                sinceLastSave: &sinceLastSave,
            )

            // Save manifest at batch boundaries so progress survives crashes
            // and cancellations. Cheap — bounded by `batchSize` uploads.
            if sinceLastSave > 0 {
                do {
                    try await manifestStore.save(manifest)
                    progress.manifestSaved(entriesCount: manifest.entries.count)
                    sinceLastSave = 0
                } catch {
                    debugPrint("Batch manifest save failed: \(error)")
                }
            }
        }

        // Retry deferred assets (single-asset timeouts from batch fallback).
        // `deferred` is keyed by cloud uuid; translate to local id for the
        // exporter, then back to cloud uuid for downstream consumers.
        for cloudUUID in deferred {
            try Task.checkCancellation()
            let localId = cloudToLocal[cloudUUID] ?? cloudUUID
            do {
                let raw = try await exporter.exportBatch(uuids: [localId])
                let result = ExportResponse(
                    results: raw.results.map { remapToCloud($0, using: localToCloud) },
                    errors: raw.errors.map { remapToCloud($0, using: localToCloud) },
                )
                recordFailures(result.errors)
                try await uploadExported(
                    result, ctx: ctx,
                    manifest: &manifest, report: &report,
                    sinceLastSave: &sinceLastSave,
                )
            } catch {
                let msg = String(describing: error)
                report.appendError(uuid: cloudUUID, message: msg)
                report.failed += 1
                let filename = assetByUUID[cloudUUID]?.originalFilename ?? cloudUUID
                progress.assetFailed(
                    uuid: cloudUUID,
                    filename: filename,
                    message: msg,
                    classification: .other,
                )
            }
        }
    } catch is CancellationError {
        // Save progress before propagating cancellation. The retry queue
        // must be merged here too — without it, this run's recorded
        // failures plus any --limit-preserved prior queue entries are
        // silently dropped. Pass `attempted: []` so RetryQueue.merged
        // preserves every prior entry (we cannot tell which subset of
        // `pending` was actually tried before cancellation).
        if sinceLastSave > 0 {
            try? await manifestStore.save(manifest)
            progress.manifestSaved(entriesCount: manifest.entries.count)
        }
        try? unavailableStore?.save(unavailable)
        persistRetryQueue(
            retryQueue: retryQueue,
            unavailable: unavailable,
            report: report,
            attempted: [],
            failureClassifications: failureClassifications,
        )
        throw CancellationError()
    }

    try await finalizeBackup(
        manifest: manifest,
        manifestStore: manifestStore,
        sinceLastSave: sinceLastSave,
        unavailable: unavailable,
        unavailableStore: unavailableStore,
        retryQueue: retryQueue,
        report: report,
        pending: pending,
        failureClassifications: failureClassifications,
        progress: progress,
    )

    return report
}

// swiftlint:enable function_body_length

/// Persist manifest, unavailable set, and retry queue at the end of a run.
private func finalizeBackup(
    manifest: Manifest,
    manifestStore: any ManifestStoring,
    sinceLastSave: Int,
    unavailable: UnavailableAssets,
    unavailableStore: (any UnavailableAssetStoring)?,
    retryQueue: (any RetryQueueProviding)?,
    report: BackupReport,
    pending: [AssetInfo],
    failureClassifications: [String: ExportClassification],
    progress: any BackupProgressDelegate,
) async throws {
    if sinceLastSave > 0 {
        try await manifestStore.save(manifest)
        progress.manifestSaved(entriesCount: manifest.entries.count)
    }

    do {
        try unavailableStore?.save(unavailable)
    } catch {
        debugPrint("Failed to save unavailable assets store: \(error)")
    }

    persistRetryQueue(
        retryQueue: retryQueue,
        unavailable: unavailable,
        report: report,
        attempted: Set(pending.map(\.uuid)),
        failureClassifications: failureClassifications,
    )

    progress.backupCompleted(
        uploaded: report.uploaded,
        failed: report.failed,
        totalBytes: report.totalBytes,
    )
}

/// Merge this run's failures into the on-disk retry queue. UUIDs marked
/// unavailable are excluded (retrying is futile). UUIDs in the prior queue
/// that weren't attempted this run (cut off by `--limit` or cancellation)
/// are preserved by passing them through `attempted: []` or by listing the
/// confirmed-attempted set.
///
/// Also called from `runBackup`'s `CancellationError` catch block so that
/// in-progress failures and prior `--limit`-preserved entries are not
/// silently dropped on Ctrl+C.
private func persistRetryQueue(
    retryQueue: (any RetryQueueProviding)?,
    unavailable: UnavailableAssets,
    report: BackupReport,
    attempted: Set<String>,
    failureClassifications: [String: ExportClassification],
) {
    let retryableErrors = report.errors.filter { !unavailable.contains($0.uuid) }
    let failures: [FailureRecord] = retryableErrors.map { entry in
        FailureRecord(
            uuid: entry.uuid,
            classification: failureClassifications[entry.uuid] ?? .other,
            message: entry.message,
        )
    }
    let merged = RetryQueue.merged(
        previous: retryQueue?.load(),
        attempted: attempted,
        failures: failures,
        now: formatISO8601(Date()),
    )
    do {
        if merged.entries.isEmpty {
            try retryQueue?.clear()
        } else {
            try retryQueue?.save(merged)
        }
    } catch {
        debugPrint("Failed to update retry queue: \(error)")
    }
}
