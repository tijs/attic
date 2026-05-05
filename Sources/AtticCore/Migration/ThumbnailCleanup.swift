import Foundation

/// Result of a `runThumbnailCleanup` invocation.
public struct ThumbnailCleanupResult: Sendable {
    public var deleted: Int
    public var bytes: Int64
    /// Per-key delete failures (key → error description). Empty on full success.
    /// Mirrors `MigrationReport.errors` shape so the runner can fold these into
    /// a partial-failure error path without `Sendable` issues with `Error`.
    public var failed: [String: String]

    public init(deleted: Int, bytes: Int64, failed: [String: String]) {
        self.deleted = deleted
        self.bytes = bytes
        self.failed = failed
    }
}

/// S3 prefix where viewer-generated thumbnails were uploaded prior to beta.16.
/// Hard-coded — `S3Paths.thumbnailKey` was removed when the viewer was
/// retired; reintroducing a public helper for a one-shot cleanup is needless
/// surface.
private let thumbnailsPrefix = "thumbnails/"

/// One-shot cleanup of `thumbnails/` orphans left by the removed viewer
/// subcommand. Lists everything under the prefix, then deletes per-key with
/// bounded concurrency. Idempotent: re-runs after partial failures re-list and
/// retry.
///
/// - Parameters:
///   - s3: S3 provider.
///   - dryRun: When `true`, returns the count + bytes without deleting.
///   - progress: Called periodically with `(deletedCount, totalCount)` for
///     the runner's progress callback. Optional in spirit; pass a no-op.
///   - concurrency: Max in-flight `deleteObject` calls. Default `16` to
///     mirror `MigrationRunner.rewriteMetadataJSONs`.
public func runThumbnailCleanup(
    s3: any S3Providing,
    dryRun: Bool,
    progress: @Sendable @escaping (Int, Int) -> Void,
    concurrency: Int = 16,
) async throws -> ThumbnailCleanupResult {
    // Step 1 — list everything. `URLSessionS3Client.listObjects` paginates
    // internally with continuation tokens; we get the full key list back.
    let listed = try await s3.listObjects(prefix: thumbnailsPrefix)
    let totalBytes = Int64(listed.reduce(0) { $0 + $1.size })

    if dryRun {
        return ThumbnailCleanupResult(
            deleted: listed.count,
            bytes: totalBytes,
            failed: [:],
        )
    }

    if listed.isEmpty {
        return ThumbnailCleanupResult(deleted: 0, bytes: 0, failed: [:])
    }

    // Step 2 — bounded fan-out per key. 404 already counts as success in S3
    // semantics; the singular `deleteObject` is idempotent. Per-key failures
    // are collected, not thrown, so the caller can decide whether to flip the
    // applied flag.
    let counter = DeleteCounter()
    let total = listed.count

    await withTaskGroup(of: Void.self) { group in
        var cursor = 0
        let initial = min(concurrency, listed.count)
        for _ in 0 ..< initial {
            let item = listed[cursor]
            cursor += 1
            group.addTask {
                await deleteSingle(s3: s3, item: item, counter: counter, total: total, progress: progress)
            }
        }
        while await group.next() != nil {
            if cursor < listed.count {
                let item = listed[cursor]
                cursor += 1
                group.addTask {
                    await deleteSingle(s3: s3, item: item, counter: counter, total: total, progress: progress)
                }
            }
        }
    }

    let deleted = await counter.deletedCount
    let bytes = await counter.deletedBytes
    let failed = await counter.failed
    return ThumbnailCleanupResult(deleted: deleted, bytes: bytes, failed: failed)
}

private func deleteSingle(
    s3: any S3Providing,
    item: S3ListObject,
    counter: DeleteCounter,
    total: Int,
    progress: @Sendable @escaping (Int, Int) -> Void,
) async {
    do {
        try await s3.deleteObject(key: item.key)
        let n = await counter.recordDeleted(bytes: Int64(item.size))
        if n % 250 == 0 || n == total {
            progress(n, total)
        }
    } catch {
        await counter.recordFailure(key: item.key, message: String(describing: error))
    }
}

private actor DeleteCounter {
    private(set) var deletedCount: Int = 0
    private(set) var deletedBytes: Int64 = 0
    private(set) var failed: [String: String] = [:]

    func recordDeleted(bytes: Int64) -> Int {
        deletedCount += 1
        deletedBytes += bytes
        return deletedCount
    }

    func recordFailure(key: String, message: String) {
        failed[key] = message
    }
}
