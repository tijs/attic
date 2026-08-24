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

    @Flag(name: .long, help: "Emit machine-readable JSON Lines on stdout.")
    var json: Bool = false

    @Option(name: .long, help: "Shell command to run after a fully successful backup.")
    var onSuccess: String?

    @Option(name: .long, help: "Shell command to run after a failed backup.")
    var onFailure: String?

    func run() async throws {
        // Signal the outcome for unattended runs: run the matching hook and
        // exit non-zero when any upload failed, so launchd/monitors can
        // detect a bad run instead of scraping logs. The failure boundary
        // covers setup too (config, keychain, manifest, Photos permission),
        // not just the upload loop — an aborted run is still a failed run.
        let jsonProgress = json ? BackupJSONProgressDelegate() : nil
        let successCommand = onSuccess
        let failureCommand = onFailure
        let json = json
        let execute: @Sendable () async throws -> BackupReport
        #if DEBUG
            execute = CLIRegressionHarness.backupOperation {
                try await executeBackup(jsonProgress: jsonProgress)
            }
        #else
            execute = { try await executeBackup(jsonProgress: jsonProgress) }
        #endif
        try await Self.performBackup(
            dryRun: dryRun,
            jsonProgress: jsonProgress,
            execute: execute,
            successHook: { report in
                Self.runHook(successCommand, result: "success", report: report, json: json)
            },
            failureHook: { report in
                Self.runHook(failureCommand, result: "failure", report: report, json: json)
            },
        )
    }

    static func performBackup(
        dryRun: Bool,
        jsonProgress: BackupJSONProgressDelegate?,
        execute: @escaping @Sendable () async throws -> BackupReport,
        successHook: @escaping @Sendable (BackupReport) -> Void,
        failureHook: @escaping @Sendable (BackupReport?) -> Void,
    ) async throws {
        #if DEBUG
            let signalHandlersInstalled = CLIRegressionHarness.signalHandlersInstalled
        #else
            let signalHandlersInstalled: @Sendable () -> Void = {}
        #endif
        try await CLISignalCancellation.run(onHandlersInstalled: signalHandlersInstalled) {
            try await performBackupAfterSignalBridge(
                dryRun: dryRun,
                jsonProgress: jsonProgress,
                execute: execute,
                successHook: successHook,
                failureHook: failureHook,
            )
        }
    }

    private static func performBackupAfterSignalBridge(
        dryRun: Bool,
        jsonProgress: BackupJSONProgressDelegate?,
        execute: @Sendable () async throws -> BackupReport,
        successHook: @Sendable (BackupReport) -> Void,
        failureHook: @Sendable (BackupReport?) -> Void,
    ) async throws {
        let report: BackupReport
        do {
            report = try await execute()
        } catch {
            jsonProgress?.finishFatal(cancelled: error is CancellationError)
            failureHook(nil)
            throw error
        }

        jsonProgress?.finish(report: report, dryRun: dryRun)
        if report.failed > 0 {
            failureHook(report)
            throw ExitCode(1)
        }
        successHook(report)
    }

    private func executeBackup(jsonProgress: BackupJSONProgressDelegate?) async throws -> BackupReport {
        try await Dependencies.ensureManifestMigrated(statusToStderr: json)

        let isTTY = !json && isatty(STDOUT_FILENO) != 0
        if !isTTY {
            // Force line buffering so launchd-captured logs flush per line
            // instead of every ~4 KB. Without this the log file looks empty
            // for minutes during long PhotoKit prep / batch phases.
            setlinebuf(stdout)
        }
        let spinner = isTTY ? PreparationSpinner() : nil
        spinner?.start()
        defer { spinner?.stop() }

        spinner?.updateStatus("Loading configuration...")
        let (_, s3, manifestStore) = try Dependencies.makeBackupDeps()

        spinner?.updateStatus("Loading manifest from S3...")
        var manifest = try await Dependencies.loadManifest(store: manifestStore)

        spinner?.updateStatus("Scanning Photos library...")
        let assets = try await Dependencies.loadAssetsAsync()

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
        defer { renderer?.finish() }
        let progress: any BackupProgressDelegate = if let jsonProgress {
            jsonProgress
        } else if let renderer {
            renderer
        } else {
            LogProgressDelegate()
        }

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

        if !isTTY, !json {
            let summary = "Backup complete: \(report.uploaded) uploaded, "
                + "\(report.failed) failed (\(formatBytes(report.totalBytes)))"
            print(summary)
        }

        return report
    }

    static func hookCommand(_ command: String, json: Bool) -> String {
        json ? "exec 1>&2; \(command)" : command
    }

    private static func runHook(
        _ command: String?,
        result: String,
        report: BackupReport?,
        json: Bool,
    ) {
        guard let command else { return }
        PostRunHook.run(
            command: hookCommand(command, json: json),
            environment: PostRunHook.environment(result: result, report: report),
        )
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

    func assetFailed(uuid: String, filename: String, message: String, classification: ExportClassification) {
        let suffix = classification == .permanentlyUnavailable ? " (permanently unavailable)" : ""
        print("  ✗ \(filename): \(message)\(suffix)")
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
