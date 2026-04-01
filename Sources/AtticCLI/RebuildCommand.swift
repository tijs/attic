import ArgumentParser
import AtticCore

struct RebuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebuild",
        abstract: "Rebuild manifest from S3 metadata files (disaster recovery).",
    )

    func run() async throws {
        let (_, s3, manifestStore) = try Dependencies.makeBackupDeps()

        print("Rebuilding manifest from S3 metadata...")

        let (manifest, report) = try await runRebuildManifest(
            s3: s3, manifestStore: manifestStore,
        )

        print("")
        print("Rebuild Results")
        print("===============")
        print("Recovered: \(report.recovered)")
        print("Skipped:   \(report.skipped)")
        print("Errors:    \(report.errors.count)")
        print("")
        print("Manifest saved with \(manifest.entries.count) entries.")

        if !report.errors.isEmpty {
            print("")
            for err in report.errors.prefix(10) {
                print("  ✗ \(err.key): \(err.message)")
            }
        }
    }
}
