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
) async throws -> BackupReport {
    // Filter to pending assets, optionally by type
    var pending = assets.filter { asset in
        if manifest.isBackedUp(asset.uuid) { return false }
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

    // Process in batches (wrapped to save manifest on cancellation)
    let totalBatches = (pending.count + options.batchSize - 1) / options.batchSize

    do {
        for batchIndex in 0 ..< totalBatches {
            try Task.checkCancellation()

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
        throw CancellationError()
    }

    // Final save
    if sinceLastSave > 0 {
        try await manifestStore.save(manifest)
        progress.manifestSaved(entriesCount: manifest.entries.count)
    }

    // Update retry queue: save failed UUIDs for next run, or clear on full success
    if report.errors.isEmpty {
        do {
            try retryQueue?.clear()
        } catch {
            debugPrint("Failed to clear retry queue: \(error)")
        }
    } else {
        let failedUUIDs = report.errors.map(\.uuid)
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

// MARK: - Upload context and helper

/// Bundles the non-mutating dependencies for uploadExported, reducing parameter count
/// and making the recursive retry call less error-prone.
private struct UploadContext {
    let assetByUUID: [String: AssetInfo]
    let s3: any S3Providing
    let manifestStore: any ManifestStoring
    let saveInterval: Int
    let concurrency: Int
    let progress: any BackupProgressDelegate
    let networkMonitor: (any NetworkMonitoring)?
    let networkTimeout: Duration
    let maxPauseRetries: Int
}

// swiftlint:disable:next function_body_length cyclomatic_complexity
private func uploadExported(
    _ batchResult: ExportResponse,
    ctx: UploadContext,
    manifest: inout Manifest,
    report: inout BackupReport,
    sinceLastSave: inout Int,
    pauseRetryCount: Int = 0,
) async throws {
    // Record export errors
    for err in batchResult.errors {
        let filename = ctx.assetByUUID[err.uuid]?.originalFilename ?? err.uuid
        ctx.progress.assetFailed(uuid: err.uuid, filename: filename, message: err.message)
        report.appendError(uuid: err.uuid, message: err.message)
        report.failed += 1
    }

    let exports = batchResult.results
    if exports.isEmpty { return }

    // Build upload inputs (compute S3 keys on the caller's task to propagate errors)
    var inputs: [UploadInput] = []
    for exported in exports {
        guard let asset = ctx.assetByUUID[exported.uuid] else { continue }
        let ext = S3Paths.extensionFromUTIOrFilename(
            uti: asset.uniformTypeIdentifier,
            filename: asset.originalFilename ?? "unknown",
        )
        let s3Key = try S3Paths.originalKey(
            uuid: asset.uuid,
            dateCreated: asset.creationDate,
            extension: ext,
        )
        inputs.append(UploadInput(exported: exported, asset: asset, s3Key: s3Key, ext: ext))
    }

    // Track inputs by UUID for retry lookup
    let inputByUUID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.exported.uuid, $0) })

    // Concurrent uploads with bounded TaskGroup
    let effectiveConcurrency = max(1, ctx.concurrency)
    var networkPaused = false
    var retryInputs: [UploadInput] = []
    var retryUUIDs: Set<String> = []

    try await withThrowingTaskGroup(of: UploadResult.self) { group in
        var cursor = 0

        // Seed initial tasks
        for _ in 0 ..< min(effectiveConcurrency, inputs.count) {
            let input = inputs[cursor]
            cursor += 1
            ctx.progress.assetStarting(
                uuid: input.asset.uuid,
                filename: input.asset.originalFilename ?? "unknown",
                size: actualFileSize(input),
            )
            group.addTask {
                await uploadSingleAsset(input: input, s3: ctx.s3, progress: ctx.progress)
            }
        }

        // Process results and enqueue next
        for try await result in group {
            try Task.checkCancellation()

            if let checksum = result.checksum, result.error == nil {
                manifest.markBackedUp(
                    uuid: result.uuid,
                    s3Key: result.s3Key,
                    checksum: checksum,
                    size: result.size,
                )
                sinceLastSave += 1
                report.uploaded += 1
                report.totalBytes += result.size
                ctx.progress.assetUploaded(
                    uuid: result.uuid,
                    filename: result.filename,
                    type: result.type,
                    size: result.size,
                )

                // Periodic manifest save
                if sinceLastSave >= ctx.saveInterval {
                    do {
                        try await ctx.manifestStore.save(manifest)
                        ctx.progress.manifestSaved(entriesCount: manifest.entries.count)
                        sinceLastSave = 0
                    } catch {
                        debugPrint("Periodic manifest save failed: \(error)")
                    }
                }
            } else if result.isNetworkDownError,
                      let monitor = ctx.networkMonitor,
                      await !monitor.isNetworkAvailable
            { // swiftlint:disable:this opening_brace
                // Network-down failure: queue for retry after recovery
                networkPaused = true
                if let input = inputByUUID[result.uuid] {
                    retryInputs.append(input)
                    retryUUIDs.insert(result.uuid)
                }
            } else {
                // Permanent or non-network failure
                ctx.progress.assetFailed(
                    uuid: result.uuid,
                    filename: result.filename,
                    message: result.error ?? "Unknown error",
                )
                report.appendError(uuid: result.uuid, message: result.error ?? "Unknown error")
                report.failed += 1
            }

            // Clean up staged file (skip if queued for retry)
            if !retryUUIDs.contains(result.uuid) {
                try? FileManager.default.removeItem(atPath: result.path)
            }

            // Enqueue next upload (skip if network is down — let group drain)
            if !networkPaused, cursor < inputs.count {
                let input = inputs[cursor]
                cursor += 1
                ctx.progress.assetStarting(
                    uuid: input.asset.uuid,
                    filename: input.asset.originalFilename ?? "unknown",
                    size: actualFileSize(input),
                )
                group.addTask {
                    await uploadSingleAsset(input: input, s3: ctx.s3, progress: ctx.progress)
                }
            }
        }

        // After drain: queue any remaining un-enqueued inputs for retry
        if networkPaused {
            while cursor < inputs.count {
                retryInputs.append(inputs[cursor])
                cursor += 1
            }
        }
    }

    // Network pause/resume: wait for recovery and retry
    if networkPaused, !retryInputs.isEmpty {
        guard let monitor = ctx.networkMonitor else { return }

        // Save manifest before waiting (preserve progress)
        if sinceLastSave > 0 {
            do {
                try await ctx.manifestStore.save(manifest)
                ctx.progress.manifestSaved(entriesCount: manifest.entries.count)
                sinceLastSave = 0
            } catch {
                debugPrint("Pre-pause manifest save failed: \(error)")
            }
        }

        ctx.progress.backupPaused(reason: "Waiting for network...")
        let recovered = try await monitor.waitForNetwork(timeout: ctx.networkTimeout)
        ctx.progress.backupResumed()

        if recovered, pauseRetryCount < ctx.maxPauseRetries {
            // Build a synthetic ExportResponse from retry inputs
            let retryResults = retryInputs.map(\.exported)
            let retryResponse = ExportResponse(results: retryResults, errors: [])

            do {
                try await uploadExported(
                    retryResponse, ctx: ctx,
                    manifest: &manifest, report: &report,
                    sinceLastSave: &sinceLastSave,
                    pauseRetryCount: pauseRetryCount + 1,
                )
            } catch {
                // Clean up staged files before propagating
                for input in retryInputs {
                    try? FileManager.default.removeItem(atPath: input.exported.path)
                }
                throw error
            }
        } else {
            // Timeout or max retries — record failures
            let reason = recovered
                ? "Max network pause retries exceeded"
                : "Network unavailable"
            for input in retryInputs {
                let filename = input.asset.originalFilename ?? input.exported.uuid
                ctx.progress.assetFailed(uuid: input.exported.uuid, filename: filename, message: reason)
                report.appendError(uuid: input.exported.uuid, message: reason)
                report.failed += 1
                try? FileManager.default.removeItem(atPath: input.exported.path)
            }
        }
    }
}
