import ArgumentParser
import AtticCore

struct VerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify backed-up assets exist in S3."
    )

    @Option(name: .long, help: "Number of concurrent verification requests.")
    var concurrency: Int = 20

    func run() async throws {
        let (_, s3, manifestStore) = try Dependencies.makeBackupDeps()
        let manifest = try await Dependencies.loadManifest(store: manifestStore)

        guard !manifest.entries.isEmpty else {
            debugPrint("Manifest is empty — nothing to verify.")
            return
        }

        debugPrint("Verifying \(manifest.entries.count) assets...")

        let report = try await runVerify(manifest: manifest, s3: s3, concurrency: concurrency)

        debugPrint("")
        debugPrint("Verify Results")
        debugPrint("==============")
        debugPrint("OK:        \(report.ok)")
        debugPrint("Missing:   \(report.missing)")
        debugPrint("Errors:    \(report.failed)")

        if !report.errors.isEmpty {
            debugPrint("")
            debugPrint("Issues:")
            for err in report.errors.prefix(20) {
                debugPrint("  \(err.uuid): \(err.message)")
            }
            if report.errors.count > 20 {
                debugPrint("  ... and \(report.errors.count - 20) more")
            }
        }
    }
}
