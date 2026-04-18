import Foundation
import LadderKit

/// Bundles the non-mutating dependencies for uploadExported, reducing parameter count
/// and making the recursive retry call less error-prone.
struct UploadContext {
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

/// Upload exported assets to S3 with bounded concurrency, and handle network-pause retries.
// swiftlint:disable:next function_body_length cyclomatic_complexity
func uploadExported(
    _ batchResult: ExportResponse,
    ctx: UploadContext,
    manifest: inout Manifest,
    report: inout BackupReport,
    sinceLastSave: inout Int,
    pauseRetryCount: Int = 0,
) async throws {
    // Record export errors. LadderKit reports full PhotoKit identifiers
    // ("UUID/L0/001"); normalize to bare UUID so retry partitioning and the
    // assetByUUID lookup line up with the pending list.
    for err in batchResult.errors {
        let bareUUID = err.uuid.split(separator: "/").first.map(String.init) ?? err.uuid
        let asset = ctx.assetByUUID[bareUUID] ?? ctx.assetByUUID[err.uuid]
        let filename = asset?.originalFilename ?? bareUUID
        ctx.progress.assetFailed(uuid: bareUUID, filename: filename, message: err.message)
        report.appendError(uuid: bareUUID, message: err.message)
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

/// Result of uploading a single asset, returned from TaskGroup child tasks.
struct UploadResult {
    let uuid: String
    let s3Key: String
    let checksum: String?
    let filename: String
    let type: AssetKind
    let size: Int
    let error: String?
    let isNetworkDownError: Bool
    let path: String
}

/// Inputs for a single concurrent upload task.
struct UploadInput {
    let exported: ExportResult
    let asset: AssetInfo
    let s3Key: String
    let ext: String
}

/// Actual file size on disk (export metadata size can be stale for iCloud-downloaded assets).
func actualFileSize(_ input: UploadInput) -> Int {
    if let attrs = try? FileManager.default.attributesOfItem(atPath: input.exported.path),
       let size = attrs[.size] as? Int, size > 0
    {
        return size
    }
    return Int(input.exported.size)
}

/// Upload a single asset (original + metadata) to S3. Returns an UploadResult.
///
/// This is a pure `@Sendable` function — no mutation of shared state.
/// Manifest updates happen in the caller's `for await` loop.
func uploadSingleAsset(
    input: UploadInput,
    s3: any S3Providing,
    progress: (any BackupProgressDelegate)? = nil,
) async -> UploadResult {
    let exported = input.exported
    let asset = input.asset
    let s3Key = input.s3Key
    let ext = input.ext
    let filename = asset.originalFilename ?? "unknown"

    let fileURL = URL(fileURLWithPath: exported.path)
    let actualSize = actualFileSize(input)

    do {
        // Upload original via file URL (avoids loading into memory)
        try await withRetry(
            onRetry: { attempt, max in
                progress?.assetRetrying(
                    uuid: asset.uuid, filename: filename, attempt: attempt, maxAttempts: max,
                )
            },
            operation: {
                try await s3.putObject(
                    key: s3Key,
                    fileURL: fileURL,
                    contentType: contentTypeForExtension(ext),
                )
            },
        )

        // Build and upload metadata
        let isoNow = formatISO8601(Date())
        let meta = buildMetadataJSON(
            asset: asset,
            s3Key: s3Key,
            checksum: "sha256:\(exported.sha256)",
            backedUpAt: isoNow,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metaData = try encoder.encode(meta)
        let metaKey = try S3Paths.metadataKey(uuid: asset.uuid)
        try await withRetry {
            try await s3.putObject(
                key: metaKey,
                body: metaData,
                contentType: "application/json",
            )
        }

        return UploadResult(
            uuid: asset.uuid,
            s3Key: s3Key,
            checksum: "sha256:\(exported.sha256)",
            filename: filename,
            type: asset.kind,
            size: actualSize,
            error: nil,
            isNetworkDownError: false,
            path: exported.path,
        )
    } catch {
        return UploadResult(
            uuid: asset.uuid,
            s3Key: s3Key,
            checksum: nil,
            filename: filename,
            type: asset.kind,
            size: actualSize,
            error: String(describing: error),
            isNetworkDownError: isNetworkDown(error),
            path: exported.path,
        )
    }
}
