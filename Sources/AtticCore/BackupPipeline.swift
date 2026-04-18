import Foundation
import LadderKit

/// Options controlling backup behavior.
public struct BackupOptions: Sendable {
    public var batchSize: Int
    public var limit: Int
    public var type: AssetKind?
    public var dryRun: Bool
    public var saveInterval: Int
    public var concurrency: Int
    public var networkTimeout: Duration
    public var maxPauseRetries: Int
    public var stagingDir: URL?

    public init(
        batchSize: Int = 10,
        limit: Int = 0,
        type: AssetKind? = nil,
        dryRun: Bool = false,
        saveInterval: Int = 25,
        concurrency: Int = 6,
        networkTimeout: Duration = .seconds(900),
        maxPauseRetries: Int = 3,
        stagingDir: URL? = nil,
    ) {
        self.batchSize = batchSize
        self.limit = limit
        self.type = type
        self.dryRun = dryRun
        self.saveInterval = saveInterval
        self.concurrency = concurrency
        self.networkTimeout = networkTimeout
        self.maxPauseRetries = maxPauseRetries
        self.stagingDir = stagingDir
    }
}

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

/// Export a batch. On batch timeout, fall back to per-asset exports and
/// track UUIDs that still time out in `deferred` for a final retry pass.
/// Returns the combined response (reclaimed + freshly exported).
func exportBatchWithFallback(
    uuids: [String],
    reclaimed: [ExportResult],
    exporter: any ExportProviding,
    deferred: inout [String],
    assetByUUID: [String: AssetInfo],
    report: inout BackupReport,
    progress: any BackupProgressDelegate,
) async throws -> ExportResponse {
    if uuids.isEmpty {
        return ExportResponse(results: reclaimed, errors: [])
    }

    do {
        let exported = try await exporter.exportBatch(uuids: uuids)
        return ExportResponse(
            results: reclaimed + exported.results,
            errors: exported.errors,
        )
    } catch let error as ExportProviderError where error.isTimeout {
        // Batch timeout: retry each asset individually
        var results = reclaimed
        var errors: [LadderKit.ExportError] = []
        for uuid in uuids {
            try Task.checkCancellation()
            do {
                let single = try await exporter.exportBatch(uuids: [uuid])
                results.append(contentsOf: single.results)
                errors.append(contentsOf: single.errors)
            } catch let innerError as ExportProviderError where innerError.isTimeout {
                deferred.append(uuid)
            } catch {
                let msg = String(describing: error)
                report.appendError(uuid: uuid, message: msg)
                report.failed += 1
                let filename = assetByUUID[uuid]?.originalFilename ?? uuid
                progress.assetFailed(uuid: uuid, filename: filename, message: msg)
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
        saveInterval: options.saveInterval,
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

    // Emit initial and between-batch concurrency limit updates.
    var lastEmittedLimit: Int?
    if let controller = adaptiveController {
        let limit = await controller.currentLimit()
        progress.concurrencyChanged(limit: limit)
        lastEmittedLimit = limit
    }

    do {
        for batchIndex in 0 ..< totalBatches {
            try Task.checkCancellation()

            if let controller = adaptiveController {
                let limit = await controller.currentLimit()
                if limit != lastEmittedLimit {
                    progress.concurrencyChanged(limit: limit)
                    lastEmittedLimit = limit
                }
            }

            let start = batchIndex * options.batchSize
            let end = min(start + options.batchSize, pending.count)
            let batch = Array(pending[start ..< end])
            let batchUUIDs = batch.map(\.uuid)

            progress.batchStarted(
                batchNumber: batchIndex + 1,
                totalBatches: totalBatches,
                assetCount: batch.count,
            )

            var reclaimedResults: [ExportResult] = []
            var uuidsToExport = batchUUIDs
            if let stagingDir = options.stagingDir {
                let reclaim = reclaimStagedFiles(uuids: batchUUIDs, stagingDir: stagingDir)
                reclaimedResults = reclaim.reclaimed
                uuidsToExport = reclaim.remaining
            }

            let batchResult = try await exportBatchWithFallback(
                uuids: uuidsToExport,
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
        }

        // Retry deferred assets (single-asset timeouts from batch fallback)
        for uuid in deferred {
            try Task.checkCancellation()
            do {
                let result = try await exporter.exportBatch(uuids: [uuid])
                recordFailures(result.errors)
                try await uploadExported(
                    result, ctx: ctx,
                    manifest: &manifest, report: &report,
                    sinceLastSave: &sinceLastSave,
                )
            } catch {
                let msg = String(describing: error)
                report.appendError(uuid: uuid, message: msg)
                report.failed += 1
                let filename = assetByUUID[uuid]?.originalFilename ?? uuid
                progress.assetFailed(uuid: uuid, filename: filename, message: msg)
            }
        }
    } catch is CancellationError {
        // Save progress before propagating cancellation
        if sinceLastSave > 0 {
            try? await manifestStore.save(manifest)
            progress.manifestSaved(entriesCount: manifest.entries.count)
        }
        try? unavailableStore?.save(unavailable)
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

    // Merge this run's failures into the retry queue. UUIDs marked unavailable
    // are excluded (retrying is futile). UUIDs in the prior queue that weren't
    // attempted this run (cut off by --limit) are preserved.
    let retryableErrors = report.errors.filter { !unavailable.contains($0.uuid) }
    let attempted = Set(pending.map(\.uuid))
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

    progress.backupCompleted(
        uploaded: report.uploaded,
        failed: report.failed,
        totalBytes: report.totalBytes,
    )
}
