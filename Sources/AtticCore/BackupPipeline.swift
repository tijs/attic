import Foundation
import LadderKit

/// Shared ISO8601 formatter — reused across all pipeline operations.
nonisolated(unsafe) let isoFormatter = ISO8601DateFormatter()

/// Shared JSON encoder for metadata uploads.
let metadataEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}()

/// Maximum number of errors to keep in a report (prevents unbounded growth).
let maxReportErrors = 1000

/// Options controlling backup behavior.
public struct BackupOptions: Sendable {
    public var batchSize: Int
    public var limit: Int
    public var type: AssetKind?
    public var dryRun: Bool
    public var saveInterval: Int

    public init(
        batchSize: Int = 50,
        limit: Int = 0,
        type: AssetKind? = nil,
        dryRun: Bool = false,
        saveInterval: Int = 50
    ) {
        self.batchSize = batchSize
        self.limit = limit
        self.type = type
        self.dryRun = dryRun
        self.saveInterval = saveInterval
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

/// Run the backup pipeline: filter → batch → export → upload → manifest.
public func runBackup(
    assets: [AssetInfo],
    manifest: inout Manifest,
    manifestStore: any ManifestStoring,
    exporter: any ExportProviding,
    s3: any S3Providing,
    options: BackupOptions = BackupOptions(),
    progress: any BackupProgressDelegate = NullProgressDelegate()
) async throws -> BackupReport {
    // Filter to pending assets, optionally by type
    var pending = assets.filter { asset in
        if manifest.isBackedUp(asset.uuid) { return false }
        if let type = options.type, asset.kind != type { return false }
        return true
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
        if asset.kind == .photo { photoCount += 1 }
        else { videoCount += 1 }
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

    // Process in batches
    let totalBatches = (pending.count + options.batchSize - 1) / options.batchSize

    for batchIndex in 0..<totalBatches {
        try Task.checkCancellation()

        let start = batchIndex * options.batchSize
        let end = min(start + options.batchSize, pending.count)
        let batch = Array(pending[start..<end])
        let batchUUIDs = batch.map(\.uuid)

        progress.batchStarted(
            batchNumber: batchIndex + 1,
            totalBatches: totalBatches,
            assetCount: batch.count
        )

        // 1. Export via LadderKit
        let batchResult: ExportResponse
        do {
            batchResult = try await exporter.exportBatch(uuids: batchUUIDs)
        } catch let error as ExportProviderError where error.isTimeout {
            // Batch timeout: retry each asset individually
            var combinedResults: [ExportResult] = []
            var combinedErrors: [LadderKit.ExportError] = []
            for uuid in batchUUIDs {
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
                combined, assetByUUID: assetByUUID, s3: s3,
                manifest: &manifest, manifestStore: manifestStore,
                report: &report, sinceLastSave: &sinceLastSave,
                saveInterval: options.saveInterval,
                progress: progress
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

        // 2. Upload exported assets
        try await uploadExported(
            batchResult, assetByUUID: assetByUUID, s3: s3,
            manifest: &manifest, manifestStore: manifestStore,
            report: &report, sinceLastSave: &sinceLastSave,
            saveInterval: options.saveInterval,
            progress: progress
        )
    }

    // Retry deferred assets
    if !deferred.isEmpty {
        for uuid in deferred {
            try Task.checkCancellation()
            do {
                let result = try await exporter.exportBatch(uuids: [uuid])
                try await uploadExported(
                    result, assetByUUID: assetByUUID, s3: s3,
                    manifest: &manifest, manifestStore: manifestStore,
                    report: &report, sinceLastSave: &sinceLastSave,
                    saveInterval: options.saveInterval,
                    progress: progress
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

    // Final save
    if sinceLastSave > 0 {
        try await manifestStore.save(manifest)
        progress.manifestSaved(entriesCount: manifest.entries.count)
    }

    progress.backupCompleted(
        uploaded: report.uploaded,
        failed: report.failed,
        totalBytes: report.totalBytes
    )

    return report
}

// MARK: - Upload helper

private func uploadExported(
    _ batchResult: ExportResponse,
    assetByUUID: [String: AssetInfo],
    s3: any S3Providing,
    manifest: inout Manifest,
    manifestStore: any ManifestStoring,
    report: inout BackupReport,
    sinceLastSave: inout Int,
    saveInterval: Int,
    progress: any BackupProgressDelegate
) async throws {
    // Record export errors
    for err in batchResult.errors {
        let filename = assetByUUID[err.uuid]?.originalFilename ?? err.uuid
        progress.assetFailed(uuid: err.uuid, filename: filename, message: err.message)
        report.appendError(uuid: err.uuid, message: err.message)
        report.failed += 1
    }

    // Upload successful exports
    for exported in batchResult.results {
        try Task.checkCancellation()

        guard let asset = assetByUUID[exported.uuid] else { continue }

        let ext = S3Paths.extensionFromUTIOrFilename(
            uti: asset.uniformTypeIdentifier,
            filename: asset.originalFilename ?? "unknown"
        )
        let s3Key = try S3Paths.originalKey(
            uuid: asset.uuid,
            dateCreated: asset.creationDate,
            extension: ext
        )

        do {
            // Upload original via file URL (avoids loading into memory)
            let fileURL = URL(fileURLWithPath: exported.path)
            try await withRetry {
                try await s3.putObject(
                    key: s3Key,
                    fileURL: fileURL,
                    contentType: contentTypeForExtension(ext)
                )
            }

            // Build and upload metadata
            let isoNow = isoFormatter.string(from: Date())
            let meta = buildMetadataJSON(
                asset: asset,
                s3Key: s3Key,
                checksum: "sha256:\(exported.sha256)",
                backedUpAt: isoNow
            )
            let metaData = try metadataEncoder.encode(meta)
            let metaKey = try S3Paths.metadataKey(uuid: asset.uuid)
            try await withRetry {
                try await s3.putObject(
                    key: metaKey,
                    body: metaData,
                    contentType: "application/json"
                )
            }

            // Update manifest
            manifest.markBackedUp(
                uuid: asset.uuid,
                s3Key: s3Key,
                checksum: "sha256:\(exported.sha256)",
                size: Int(exported.size)
            )
            sinceLastSave += 1
            report.uploaded += 1
            report.totalBytes += Int(exported.size)

            let filename = asset.originalFilename ?? "unknown"
            progress.assetUploaded(
                uuid: asset.uuid,
                filename: filename,
                type: asset.kind,
                size: Int(exported.size)
            )

            // Periodic manifest save (skip sortedKeys for speed)
            if sinceLastSave >= saveInterval {
                try await manifestStore.save(manifest)
                progress.manifestSaved(entriesCount: manifest.entries.count)
                sinceLastSave = 0
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let msg = String(describing: error)
            let filename = asset.originalFilename ?? exported.uuid
            progress.assetFailed(uuid: exported.uuid, filename: filename, message: msg)
            report.appendError(uuid: exported.uuid, message: msg)
            report.failed += 1
        }

        // Clean up staged file
        try? FileManager.default.removeItem(atPath: exported.path)
    }
}
