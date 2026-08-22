import Foundation
import LadderKit

/// Progress events emitted during backup.
///
/// Implemented by the CLI (terminal renderer) and the menu bar app (AppState).
public protocol BackupProgressDelegate: Sendable {
    /// Backup is starting with this many pending assets.
    func backupStarted(pending: Int, photos: Int, videos: Int)

    /// A batch is starting.
    func batchStarted(batchNumber: Int, totalBatches: Int, assetCount: Int)

    /// A single asset is about to start uploading.
    func assetStarting(uuid: String, filename: String, size: Int)

    /// A single asset was uploaded successfully.
    func assetUploaded(uuid: String, filename: String, type: AssetKind, size: Int)

    /// A single asset upload is being retried after a transient error.
    func assetRetrying(uuid: String, filename: String, attempt: Int, maxAttempts: Int)

    /// A single asset failed.
    func assetFailed(uuid: String, filename: String, message: String, classification: ExportClassification)

    /// Manifest was saved to S3.
    func manifestSaved(entriesCount: Int)

    /// Backup completed.
    func backupCompleted(uploaded: Int, failed: Int, totalBytes: Int)

    /// Backup paused (e.g., network lost during upload).
    func backupPaused(reason: String)

    /// Backup resumed after a pause.
    func backupResumed()

    /// Adaptive export concurrency limit changed (AIMD controller backed off
    /// or recovered).
    func concurrencyChanged(limit: Int)

    /// Human-readable diagnostic detail. Machine-readable delegates route
    /// this to stderr so their stdout contract remains parseable.
    func diagnostic(message: String)
}

/// Default no-op implementations for optional delegate methods.
public extension BackupProgressDelegate {
    func assetStarting(uuid: String, filename: String, size: Int) {}
    func assetRetrying(uuid: String, filename: String, attempt: Int, maxAttempts: Int) {}
    func backupPaused(reason: String) {}
    func backupResumed() {}
    func concurrencyChanged(limit: Int) {}
    func diagnostic(message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// No-op delegate for quiet/test runs.
public struct NullProgressDelegate: BackupProgressDelegate {
    public init() {}
    public func backupStarted(pending: Int, photos: Int, videos: Int) {}
    public func batchStarted(batchNumber: Int, totalBatches: Int, assetCount: Int) {}
    public func assetStarting(uuid: String, filename: String, size: Int) {}
    public func assetRetrying(uuid: String, filename: String, attempt: Int, maxAttempts: Int) {}
    public func assetUploaded(uuid: String, filename: String, type: AssetKind, size: Int) {}
    public func assetFailed(uuid: String, filename: String, message: String, classification: ExportClassification) {}
    public func manifestSaved(entriesCount: Int) {}
    public func backupCompleted(uploaded: Int, failed: Int, totalBytes: Int) {}
    public func concurrencyChanged(limit: Int) {}
    public func diagnostic(message: String) {}
}
