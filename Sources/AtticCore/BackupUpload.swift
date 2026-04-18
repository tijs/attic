import Foundation
import LadderKit

/// Bundles the non-mutating dependencies for uploadExported.
struct UploadContext {
    let assetByUUID: [String: AssetInfo]
    let s3: any S3Providing
    let manifestStore: any ManifestStoring
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
) async throws {
    // Record export errors for reporting (failures handled upstream by callers).
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

    // Concurrent uploads. On a network-down failure we drain the current pass,
    // wait for recovery, then loop with the queued retry set as the next pass.
    let effectiveConcurrency = max(1, ctx.concurrency)
    var passInputs = inputs
    var pauseRetryCount = 0

    while !passInputs.isEmpty {
        var networkPaused = false
        var retryInputs: [UploadInput] = []
        var retryUUIDs: Set<String> = []
        let inputByUUID = Dictionary(uniqueKeysWithValues: passInputs.map { ($0.exported.uuid, $0) })

        try await withThrowingTaskGroup(of: UploadResult.self) { group in
            var cursor = 0

            for _ in 0 ..< min(effectiveConcurrency, passInputs.count) {
                let input = passInputs[cursor]
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
                } else if result.isNetworkDownError,
                          let monitor = ctx.networkMonitor,
                          await !monitor.isNetworkAvailable
                { // swiftlint:disable:this opening_brace
                    networkPaused = true
                    if let input = inputByUUID[result.uuid] {
                        retryInputs.append(input)
                        retryUUIDs.insert(result.uuid)
                    }
                } else {
                    ctx.progress.assetFailed(
                        uuid: result.uuid,
                        filename: result.filename,
                        message: result.error ?? "Unknown error",
                    )
                    report.appendError(uuid: result.uuid, message: result.error ?? "Unknown error")
                    report.failed += 1
                }

                if !retryUUIDs.contains(result.uuid) {
                    try? FileManager.default.removeItem(atPath: result.path)
                }

                if !networkPaused, cursor < passInputs.count {
                    let input = passInputs[cursor]
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

            if networkPaused {
                while cursor < passInputs.count {
                    retryInputs.append(passInputs[cursor])
                    cursor += 1
                }
            }
        }

        guard networkPaused, !retryInputs.isEmpty else { return }
        guard let monitor = ctx.networkMonitor else { return }

        // Save progress before waiting
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
            pauseRetryCount += 1
            passInputs = retryInputs
            continue
        }

        // Timeout or max retries — record failures and clean up staged files.
        let reason = recovered ? "Max network pause retries exceeded" : "Network unavailable"
        for input in retryInputs {
            let filename = input.asset.originalFilename ?? input.exported.uuid
            ctx.progress.assetFailed(uuid: input.exported.uuid, filename: filename, message: reason)
            report.appendError(uuid: input.exported.uuid, message: reason)
            report.failed += 1
            try? FileManager.default.removeItem(atPath: input.exported.path)
        }
        return
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
        encoder.outputFormatting = .sortedKeys
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
