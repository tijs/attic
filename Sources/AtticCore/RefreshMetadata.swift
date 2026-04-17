import Foundation
import LadderKit

/// Options controlling refresh-metadata behavior.
public struct RefreshMetadataOptions: Sendable {
    public var concurrency: Int
    public var dryRun: Bool

    public init(concurrency: Int = 20, dryRun: Bool = false) {
        self.concurrency = concurrency
        self.dryRun = dryRun
    }
}

/// Result of a refresh-metadata run.
public struct RefreshMetadataReport: Sendable {
    public var updated: Int = 0
    public var skipped: Int = 0
    public var failed: Int = 0
    public var totalBytes: Int = 0
    public var errors: [(uuid: String, message: String)] = []
}

/// Progress events emitted during metadata refresh.
public protocol RefreshMetadataProgressDelegate: Sendable {
    func refreshStarted(total: Int)
    func assetRefreshed(uuid: String, filename: String)
    func assetFailed(uuid: String, message: String)
    func refreshCompleted(report: RefreshMetadataReport)
}

/// No-op refresh progress delegate.
public struct NullRefreshMetadataProgressDelegate: RefreshMetadataProgressDelegate {
    public init() {}
    public func refreshStarted(total: Int) {}
    public func assetRefreshed(uuid: String, filename: String) {}
    public func assetFailed(uuid: String, message: String) {}
    public func refreshCompleted(report: RefreshMetadataReport) {}
}

/// Re-generate and upload metadata JSON for all backed-up assets.
///
/// This is useful when the metadata schema changes or new fields are added.
/// Only processes assets that exist in both the manifest and the asset list.
public func runRefreshMetadata(
    assets: [AssetInfo],
    manifest: Manifest,
    s3: any S3Providing,
    options: RefreshMetadataOptions = RefreshMetadataOptions(),
    progress: any RefreshMetadataProgressDelegate = NullRefreshMetadataProgressDelegate(),
) async throws -> RefreshMetadataReport {
    // Only refresh assets that are in the manifest
    let backedUp = assets.filter { manifest.isBackedUp($0.uuid) }

    guard !backedUp.isEmpty else {
        let report = RefreshMetadataReport()
        progress.refreshCompleted(report: report)
        return report
    }

    progress.refreshStarted(total: backedUp.count)

    if options.dryRun {
        var report = RefreshMetadataReport()
        report.skipped = backedUp.count
        progress.refreshCompleted(report: report)
        return report
    }

    let report = RefreshReport()

    await withTaskGroup(of: Void.self) { group in
        var cursor = 0

        for _ in 0 ..< min(options.concurrency, backedUp.count) {
            let asset = backedUp[cursor]
            cursor += 1
            group.addTask {
                await refreshSingle(
                    asset: asset,
                    manifest: manifest,
                    s3: s3,
                    report: report,
                    progress: progress,
                )
            }
        }

        for await _ in group {
            if cursor < backedUp.count {
                let asset = backedUp[cursor]
                cursor += 1
                group.addTask {
                    await refreshSingle(
                        asset: asset,
                        manifest: manifest,
                        s3: s3,
                        report: report,
                        progress: progress,
                    )
                }
            }
        }
    }

    let finalReport = await report.snapshot()
    progress.refreshCompleted(report: finalReport)
    return finalReport
}

// MARK: - Internals

private actor RefreshReport {
    var updated = 0
    var failed = 0
    var totalBytes = 0
    var errors: [(uuid: String, message: String)] = []

    func markUpdated(bytes: Int) {
        updated += 1
        totalBytes += bytes
    }

    func markFailed(_ uuid: String, _ message: String) {
        failed += 1
        if errors.count < maxReportErrors {
            errors.append((uuid: uuid, message: message))
        }
    }

    func snapshot() -> RefreshMetadataReport {
        RefreshMetadataReport(
            updated: updated, skipped: 0, failed: failed,
            totalBytes: totalBytes, errors: errors,
        )
    }
}

private func refreshSingle(
    asset: AssetInfo,
    manifest: Manifest,
    s3: any S3Providing,
    report: RefreshReport,
    progress: any RefreshMetadataProgressDelegate,
) async {
    guard let entry = manifest.entries[asset.uuid] else { return }

    do {
        let meta = buildMetadataJSON(
            asset: asset,
            s3Key: entry.s3Key,
            checksum: entry.checksum,
            backedUpAt: entry.backedUpAt,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(meta)
        let metaKey = try S3Paths.metadataKey(uuid: asset.uuid)

        try await withRetry {
            try await s3.putObject(key: metaKey, body: data, contentType: "application/json")
        }

        await report.markUpdated(bytes: data.count)
        let filename = asset.originalFilename ?? asset.uuid
        progress.assetRefreshed(uuid: asset.uuid, filename: filename)
    } catch {
        let msg = String(describing: error)
        await report.markFailed(asset.uuid, msg)
        progress.assetFailed(uuid: asset.uuid, message: msg)
    }
}
