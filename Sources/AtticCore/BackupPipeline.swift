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

// swiftlint:disable cyclomatic_complexity function_body_length
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

    // Filter to pending assets, optionally by type
    var pending = assets.filter { asset in
        if manifest.isBackedUp(asset.uuid) { return false }
        if unavailable.contains(asset.uuid) { return false }
        if let type = options.type, asset.kind != type { return false }
        return true
    }

    // Partition retry-queue UUIDs to the front so failed assets are retried first
    if let retryUUIDs = retryQueue?.load()?.failedUUIDs {
        let retrySet = Set(retryUUIDs)
        _ = pending.partition { !retrySet.contains($0.uuid) }
    }

    // Apply limit
    if options.limit > 0 {
        pending = Array(pending.prefix(options.limit))
    }

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

    // Build UUID-to-asset lookup
    let assetByUUID = Dictionary(uniqueKeysWithValues: pending.map { ($0.uuid, $0) })

    var report = BackupReport()
    var sinceLastSave = 0
    var deferred: [String] = []

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

    // Helper: record a classified "unavailable" error. Returns true if the
    // error was an unavailable-marker (already tracked; should not be retried).
    // LadderKit may report errors using the full PhotoKit identifier
    // ("UUID/L0/001"); normalize to bare UUID so `pending` filter matches.
    func recordIfUnavailable(_ err: LadderKit.ExportError) -> Bool {
        guard err.unavailable else { return false }
        let bareUUID = err.uuid.split(separator: "/").first.map(String.init) ?? err.uuid
        let asset = assetByUUID[bareUUID] ?? assetByUUID[err.uuid]
        unavailable.record(
            uuid: bareUUID,
            filename: asset?.originalFilename,
            reason: err.message,
        )
        return true
    }

    // Process in batches (wrapped to save manifest on cancellation)
    let totalBatches = (pending.count + options.batchSize - 1) / options.batchSize

    // Emit an initial concurrency limit for UIs that want to show it, then
    // re-emit between batches whenever the AIMD controller adjusts.
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

            // 1. Reclaim previously-staged files, then export the rest via LadderKit
            var reclaimedResults: [ExportResult] = []
            var uuidsToExport = batchUUIDs
            if let stagingDir = options.stagingDir {
                let reclaim = reclaimStagedFiles(uuids: batchUUIDs, stagingDir: stagingDir)
                reclaimedResults = reclaim.reclaimed
                uuidsToExport = reclaim.remaining
            }

            let batchResult: ExportResponse
            if uuidsToExport.isEmpty {
                batchResult = ExportResponse(results: reclaimedResults, errors: [])
            } else {
                do {
                    let exported = try await exporter.exportBatch(uuids: uuidsToExport)
                    batchResult = ExportResponse(
                        results: reclaimedResults + exported.results,
                        errors: exported.errors,
                    )
                } catch let error as ExportProviderError where error.isTimeout {
                    // Batch timeout: retry each asset individually
                    var combinedResults: [ExportResult] = reclaimedResults
                    var combinedErrors: [LadderKit.ExportError] = []
                    for uuid in uuidsToExport {
                        try Task.checkCancellation()
                        do {
                            let result = try await exporter.exportBatch(uuids: [uuid])
                            combinedResults.append(contentsOf: result.results)
                            combinedErrors.append(contentsOf: result.errors)
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
                    for err in combinedErrors {
                        _ = recordIfUnavailable(err)
                    }
                    let combined = ExportResponse(results: combinedResults, errors: combinedErrors)
                    try await uploadExported(
                        combined, ctx: ctx,
                        manifest: &manifest, report: &report,
                        sinceLastSave: &sinceLastSave,
                    )
                    continue
                } catch let error as ExportProviderError where error.isPermission {
                    // Permission error: abort all remaining batches
                    let msg = String(describing: error)
                    for uuid in batchUUIDs {
                        report.appendError(uuid: uuid, message: msg)
                        report.failed += 1
                    }
                    for asset in pending[end...] {
                        report.appendError(uuid: asset.uuid, message: msg)
                        report.failed += 1
                    }
                    break
                } catch {
                    // Non-timeout error: fail the whole batch
                    let msg = String(describing: error)
                    for uuid in batchUUIDs {
                        report.appendError(uuid: uuid, message: msg)
                        report.failed += 1
                        let filename = assetByUUID[uuid]?.originalFilename ?? uuid
                        progress.assetFailed(uuid: uuid, filename: filename, message: msg)
                    }
                    continue
                }
            }

            for err in batchResult.errors {
                _ = recordIfUnavailable(err)
            }

            // 2. Upload exported assets
            try await uploadExported(
                batchResult, ctx: ctx,
                manifest: &manifest, report: &report,
                sinceLastSave: &sinceLastSave,
            )
        }

        // Retry deferred assets
        if !deferred.isEmpty {
            for uuid in deferred {
                try Task.checkCancellation()
                do {
                    let result = try await exporter.exportBatch(uuids: [uuid])
                    for err in result.errors {
                        _ = recordIfUnavailable(err)
                    }
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

    // Final save
    if sinceLastSave > 0 {
        try await manifestStore.save(manifest)
        progress.manifestSaved(entriesCount: manifest.entries.count)
    }

    // Persist unavailable set so these assets are skipped on future runs.
    do {
        try unavailableStore?.save(unavailable)
    } catch {
        debugPrint("Failed to save unavailable assets store: \(error)")
    }

    // Update retry queue: save failed UUIDs for next run, or clear on full success.
    // Exclude UUIDs we just marked unavailable — retrying them is futile.
    let retryableErrors = report.errors.filter { !unavailable.contains($0.uuid) }
    if retryableErrors.isEmpty {
        do {
            try retryQueue?.clear()
        } catch {
            debugPrint("Failed to clear retry queue: \(error)")
        }
    } else {
        let failedUUIDs = retryableErrors.map(\.uuid)
        let queue = RetryQueue(
            failedUUIDs: failedUUIDs,
            updatedAt: formatISO8601(Date()),
        )
        do {
            try retryQueue?.save(queue)
        } catch {
            debugPrint("Failed to save retry queue: \(error)")
        }
    }

    progress.backupCompleted(
        uploaded: report.uploaded,
        failed: report.failed,
        totalBytes: report.totalBytes,
    )

    return report
}

// swiftlint:enable cyclomatic_complexity function_body_length
