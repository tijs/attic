import ArgumentParser
import AtticCore
import Foundation
import LadderKit

struct BackupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup",
        abstract: "Back up photos and videos to S3.",
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
        try await Dependencies.ensureManifestMigrated()

        let isTTY = isatty(STDOUT_FILENO) != 0
        let spinner = isTTY ? PreparationSpinner() : nil
        spinner?.start()

        spinner?.updateStatus("Loading configuration...")
        let (_, s3, manifestStore) = try Dependencies.makeBackupDeps()

        spinner?.updateStatus("Loading manifest from S3...")
        var manifest = try await Dependencies.loadManifest(store: manifestStore)

        spinner?.updateStatus("Scanning Photos library...")
        let assets = await Dependencies.loadAssetsAsync()

        let assetKind: AssetKind? = switch type?.lowercased() {
        case "photo": .photo
        case "video": .video
        default: nil
        }

        // Stable staging dir — files persist across runs for reuse, cleaned per-asset after upload.
        // 0o700: staged originals are plaintext copies of the user's photos; keep them out of
        // other local accounts.
        let stagingDir = FileConfigProvider.defaultDirectory.appendingPathComponent("staging")
        try FileManager.default.createDirectory(
            at: stagingDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )

        // Adaptive export: partition by local vs iCloud availability, and let
        // the AIMD controller throttle the iCloud lane when PhotoKit pushes back.
        let localAvailability = Dependencies.loadLocalAvailability()
        let adaptiveController = AIMDController()

        let exporter = LadderKitExportProvider(
            stagingDir: stagingDir,
            localAvailability: localAvailability,
            adaptiveController: adaptiveController,
        )

        // Pre-flight permission check
        try await exporter.checkPermissions()

        spinner?.updateStatus("Comparing assets...")

        let renderer = isTTY ? TerminalRenderer(spinner: spinner) : nil
        let progress: any BackupProgressDelegate = renderer ?? LogProgressDelegate()

        let options = BackupOptions(
            batchSize: batchSize,
            limit: limit,
            type: assetKind,
            dryRun: dryRun,
            stagingDir: stagingDir,
        )

        // Prevent idle sleep during backup (released automatically via deinit)
        let powerAssertion = PowerAssertion(reason: "Backing up photos to S3")

        let report = try await runBackup(
            assets: assets,
            manifest: &manifest,
            manifestStore: manifestStore,
            exporter: exporter,
            s3: s3,
            options: options,
            progress: progress,
            networkMonitor: NWPathNetworkMonitor(),
            retryQueue: FileRetryQueueStore(),
            unavailableStore: FileUnavailableAssetStore(),
            adaptiveController: adaptiveController,
        )

        _ = powerAssertion // prevent unused warning, released in deinit

        if !isTTY {
            let summary = "Backup complete: \(report.uploaded) uploaded, "
                + "\(report.failed) failed (\(formatBytes(report.totalBytes)))"
            print(summary)
        }
    }
}

/// Simple line-by-line progress for non-TTY output (CI, pipes).
struct LogProgressDelegate: BackupProgressDelegate {
    func backupStarted(pending: Int, photos: Int, videos: Int) {
        print("Starting backup: \(pending) assets (\(photos) photos, \(videos) videos)")
    }

    func batchStarted(batchNumber: Int, totalBatches: Int, assetCount: Int) {
        print("Batch \(batchNumber)/\(totalBatches) (\(assetCount) assets)")
    }

    func assetStarting(uuid: String, filename: String, size: Int) {
        print("  → \(filename) (\(formatBytes(size)))")
    }

    func assetRetrying(uuid: String, filename: String, attempt: Int, maxAttempts: Int) {
        print("  ↻ \(filename) — retry \(attempt)/\(maxAttempts)")
    }

    func assetUploaded(uuid: String, filename: String, type: AssetKind, size: Int) {
        print("  ✓ \(filename) (\(formatBytes(size)))")
    }

    func assetFailed(uuid: String, filename: String, message: String) {
        print("  ✗ \(filename): \(message)")
    }

    func manifestSaved(entriesCount: Int) {
        print("  Manifest saved (\(entriesCount) entries)")
    }

    func backupPaused(reason: String) {
        print("  ⏸ Paused: \(reason)")
    }

    func backupResumed() {
        print("  ▶ Resumed")
    }

    func backupCompleted(uploaded: Int, failed: Int, totalBytes: Int) {
        print("Done: \(uploaded) uploaded, \(failed) failed (\(formatBytes(totalBytes)))")
    }

    func concurrencyChanged(limit: Int) {
        print("  ⚙ Concurrency → \(limit) lane\(limit == 1 ? "" : "s")")
    }
}
