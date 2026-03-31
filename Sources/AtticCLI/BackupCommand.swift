import ArgumentParser
import Foundation
import AtticCore
import LadderKit

struct BackupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup",
        abstract: "Back up photos and videos to S3."
    )

    @Option(name: .long, help: "Number of assets per export batch.")
    var batchSize: Int = 50

    @Option(name: .long, help: "Maximum number of assets to back up (0 = unlimited).")
    var limit: Int = 0

    @Option(name: .long, help: "Only back up assets of this type (photo or video).")
    var type: String?

    @Flag(name: .long, help: "Show what would be backed up without uploading.")
    var dryRun: Bool = false

    func run() async throws {
        let isTTY = isatty(STDOUT_FILENO) != 0
        let spinner = isTTY ? PreparationSpinner() : nil
        spinner?.start()

        spinner?.updateStatus("Loading configuration...")
        let (_, s3, manifestStore) = try Dependencies.makeBackupDeps()

        spinner?.updateStatus("Loading manifest from S3...")
        var manifest = try await Dependencies.loadManifest(store: manifestStore)

        spinner?.updateStatus("Scanning Photos library...")
        let assets = Dependencies.loadAssets()

        let assetKind: AssetKind? = switch type?.lowercased() {
        case "photo": .photo
        case "video": .video
        default: nil
        }

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let exporter = LadderKitExportProvider(stagingDir: stagingDir)

        // Pre-flight permission check
        try await exporter.checkPermissions()

        spinner?.updateStatus("Comparing assets...")

        let renderer = isTTY ? TerminalRenderer(spinner: spinner) : nil
        let progress: any BackupProgressDelegate = renderer ?? LogProgressDelegate()

        let options = BackupOptions(
            batchSize: batchSize,
            limit: limit,
            type: assetKind,
            dryRun: dryRun
        )

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: options,
            progress: progress
        )

        if !isTTY {
            debugPrint("Backup complete: \(report.uploaded) uploaded, \(report.failed) failed (\(formatBytes(report.totalBytes)))")
        }
    }
}

/// Simple line-by-line progress for non-TTY output (CI, pipes).
struct LogProgressDelegate: BackupProgressDelegate {
    func backupStarted(pending: Int, photos: Int, videos: Int) {
        debugPrint("Starting backup: \(pending) assets (\(photos) photos, \(videos) videos)")
    }
    func batchStarted(batchNumber: Int, totalBatches: Int, assetCount: Int) {
        debugPrint("Batch \(batchNumber)/\(totalBatches) (\(assetCount) assets)")
    }
    func assetUploaded(uuid: String, filename: String, type: AssetKind, size: Int) {
        debugPrint("  ✓ \(filename) (\(formatBytes(size)))")
    }
    func assetFailed(uuid: String, filename: String, message: String) {
        debugPrint("  ✗ \(filename): \(message)")
    }
    func manifestSaved(entriesCount: Int) {
        debugPrint("  Manifest saved (\(entriesCount) entries)")
    }
    func backupCompleted(uploaded: Int, failed: Int, totalBytes: Int) {
        debugPrint("Done: \(uploaded) uploaded, \(failed) failed (\(formatBytes(totalBytes)))")
    }
}
