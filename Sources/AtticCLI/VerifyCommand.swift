import ArgumentParser
import AtticCore

struct VerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify backed-up assets exist in S3.",
    )

    @Option(name: .long, help: "Number of concurrent verification requests.")
    var concurrency: Int = 20

    func run() async throws {
        try await Dependencies.ensureManifestMigrated()

        let (_, s3, manifestStore) = try Dependencies.makeBackupDeps()
        let manifest = try await Dependencies.loadManifest(store: manifestStore)

        guard !manifest.entries.isEmpty else {
            print("Manifest is empty — nothing to verify.")
            return
        }

        print("Verifying \(manifest.entries.count) assets...")

        let report = try await runVerify(manifest: manifest, s3: s3, concurrency: concurrency)

        print("")
        print("Verify Results")
        print("==============")
        print("OK:        \(report.ok)")
        print("Missing:   \(report.missing)")
        print("Errors:    \(report.failed)")

        if !report.errors.isEmpty {
            print("")
            print("Issues:")
            for err in report.errors.prefix(20) {
                print("  \(err.uuid): \(err.message)")
            }
            if report.errors.count > 20 {
                print("  ... and \(report.errors.count - 20) more")
            }
        }
    }
}
