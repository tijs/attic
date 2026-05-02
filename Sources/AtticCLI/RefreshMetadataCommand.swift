import ArgumentParser
import AtticCore

struct RefreshMetadataCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh-metadata",
        abstract: "Re-generate and upload metadata JSON for all backed-up assets.",
    )

    @Option(name: .long, help: "Number of concurrent uploads.")
    var concurrency: Int = 20

    @Flag(name: .long, help: "Show what would be refreshed without uploading.")
    var dryRun: Bool = false

    func run() async throws {
        try await Dependencies.ensureManifestMigrated()

        let (_, s3, manifestStore) = try Dependencies.makeBackupDeps()
        let manifest = try await Dependencies.loadManifest(store: manifestStore)
        let assets = await Dependencies.loadAssetsAsync()

        let options = RefreshMetadataOptions(concurrency: concurrency, dryRun: dryRun)

        if dryRun {
            let backedUpCount = assets.count(where: { manifest.isBackedUp($0.uuid) })
            print("Dry run: would refresh metadata for \(backedUpCount) assets.")
            return
        }

        print("Refreshing metadata for backed-up assets...")

        let report = try await runRefreshMetadata(
            assets: assets, manifest: manifest, s3: s3, options: options,
        )

        print("")
        print("Refresh Results")
        print("===============")
        print("Updated:   \(report.updated)")
        print("Failed:    \(report.failed)")
        print("Bytes:     \(formatBytes(report.totalBytes))")

        if !report.errors.isEmpty {
            print("")
            for err in report.errors.prefix(10) {
                print("  ✗ \(err.uuid): \(err.message)")
            }
        }
    }
}
