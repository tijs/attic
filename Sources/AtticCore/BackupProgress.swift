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

    /// A single asset was uploaded successfully.
    func assetUploaded(uuid: String, filename: String, type: AssetKind, size: Int)

    /// A single asset failed.
    func assetFailed(uuid: String, filename: String, message: String)

    /// Manifest was saved to S3.
    func manifestSaved(entriesCount: Int)

    /// Backup completed.
    func backupCompleted(uploaded: Int, failed: Int, totalBytes: Int)
}

/// No-op delegate for quiet/test runs.
public struct NullProgressDelegate: BackupProgressDelegate {
    public init() {}
    public func backupStarted(pending: Int, photos: Int, videos: Int) {}
    public func batchStarted(batchNumber: Int, totalBatches: Int, assetCount: Int) {}
    public func assetUploaded(uuid: String, filename: String, type: AssetKind, size: Int) {}
    public func assetFailed(uuid: String, filename: String, message: String) {}
    public func manifestSaved(entriesCount: Int) {}
    public func backupCompleted(uploaded: Int, failed: Int, totalBytes: Int) {}
}
