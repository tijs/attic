import Foundation

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

/// Cleanup-phase implementation, factored out of `MigrationRunner` so the
/// runner stays under the file-length budget. Pure: takes the dependencies
/// it needs and returns the result.
///
/// Behavior:
/// 1. Probes `thumbnails/` via a dry-run pass to get count + bytes.
/// 2. If empty — silently flips `thumbnailsCleanupApplied = true` and saves
///    (skipped on dry-run).
/// 3. If dry-run + non-empty — returns counts without prompting or deleting.
/// 4. If apply + non-empty — asks `confirmCleanup`; on `.proceed`, deletes;
///    on `.abort` or `.nonInteractive`, throws the matching
///    `MigrationRunnerError`.
/// 5. On clean delete, atomically flips the flag and saves.
func runThumbnailCleanupPhaseImpl(
    s3: any S3Providing,
    manifestStore: any ManifestStoring,
    progress: (@Sendable (String) -> Void)?,
    manifest: Manifest,
    dryRun: Bool,
    confirmCleanup: @Sendable (Int, Int64) async -> CleanupConfirmation,
) async throws -> ThumbnailCleanupResult {
    progress?("Probing thumbnails/ prefix…")
    let probe = try await runThumbnailCleanup(
        s3: s3,
        dryRun: true,
        progress: { _, _ in },
    )

    if probe.deleted == 0 {
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
        progress: { deleted, total in
            progress?("Deleted \(deleted)/\(total) thumbnails…")
        },
    )

    if !result.failed.isEmpty {
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
