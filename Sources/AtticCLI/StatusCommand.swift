import ArgumentParser
import AtticCore
import Foundation
import LadderKit

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show library stats, backup progress, and S3 manifest info.",
    )

    func run() async throws {
        let isTTY = isatty(STDOUT_FILENO) != 0
        let assets = Dependencies.loadAssets()

        let library = StatusStats.computeLibraryStats(assets)
        let types = StatusStats.computeUTIBreakdown(assets)

        var backup: BackupStats?
        var s3: S3Info?

        do {
            let (config, _, manifestStore) = try Dependencies.makeBackupDeps()
            let manifest = try await Dependencies.loadManifest(store: manifestStore)
            backup = StatusStats.computeBackupStats(assets: assets, manifest: manifest)
            s3 = StatusStats.computeS3Info(bucket: config.bucket, manifest: manifest)
        } catch CLIError.notInitialized {
            // No config — show library only with init hint
        }

        let data = DashboardData(
            version: AtticCore.version,
            library: library,
            backup: backup,
            s3: s3,
            types: types,
        )

        StatusRenderer(isTTY: isTTY).render(data)
    }
}
