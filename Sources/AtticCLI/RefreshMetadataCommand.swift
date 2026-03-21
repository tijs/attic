import ArgumentParser
import AtticCore

struct RefreshMetadataCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh-metadata",
        abstract: "Re-generate and upload metadata JSON for all backed-up assets."
    )

    @Option(name: .long, help: "Number of concurrent uploads.")
    var concurrency: Int = 20

    @Flag(name: .long, help: "Show what would be refreshed without uploading.")
    var dryRun: Bool = false

    func run() async throws {
        let (_, s3, manifestStore) = try Dependencies.makeBackupDeps()
        let manifest = try await Dependencies.loadManifest(store: manifestStore)
        let assets = Dependencies.loadAssets()

        let options = RefreshMetadataOptions(concurrency: concurrency, dryRun: dryRun)

        if dryRun {
            let backedUpCount = assets.filter { manifest.isBackedUp($0.uuid) }.count
            debugPrint("Dry run: would refresh metadata for \(backedUpCount) assets.")
            return
        }

        debugPrint("Refreshing metadata for backed-up assets...")

        let report = try await runRefreshMetadata(
            assets: assets, manifest: manifest, s3: s3, options: options
        )

        debugPrint("")
        debugPrint("Refresh Results")
        debugPrint("===============")
        debugPrint("Updated:   \(report.updated)")
        debugPrint("Failed:    \(report.failed)")
        debugPrint("Bytes:     \(formatBytes(report.totalBytes))")

        if !report.errors.isEmpty {
            debugPrint("")
            for err in report.errors.prefix(10) {
                debugPrint("  ✗ \(err.uuid): \(err.message)")
            }
        }
    }
}
