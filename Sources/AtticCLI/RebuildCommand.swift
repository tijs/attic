import ArgumentParser
import AtticCore

struct RebuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebuild",
        abstract: "Rebuild manifest from S3 metadata files (disaster recovery)."
    )

    func run() async throws {
        let (_, s3, manifestStore) = try Dependencies.makeBackupDeps()

        debugPrint("Rebuilding manifest from S3 metadata...")

        let (manifest, report) = try await runRebuildManifest(
            s3: s3, manifestStore: manifestStore
        )

        debugPrint("")
        debugPrint("Rebuild Results")
        debugPrint("===============")
        debugPrint("Recovered: \(report.recovered)")
        debugPrint("Skipped:   \(report.skipped)")
        debugPrint("Errors:    \(report.errors.count)")
        debugPrint("")
        debugPrint("Manifest saved with \(manifest.entries.count) entries.")

        if !report.errors.isEmpty {
            debugPrint("")
            for err in report.errors.prefix(10) {
                debugPrint("  ✗ \(err.key): \(err.message)")
            }
        }
    }
}
