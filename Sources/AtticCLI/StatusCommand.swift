import ArgumentParser
import AtticCore
import Foundation
import LadderKit

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show library stats, backup progress, and S3 manifest info.",
    )

    @Flag(name: .long, help: "Emit status as a single JSON object on stdout.")
    var json: Bool = false

    func run() async throws {
        let data = try await Self.buildDashboard(
            ensureMigrated: { try await Dependencies.ensureManifestMigrated() },
            loadAssets: { try await Dependencies.loadAssetsAsync() },
            loadLocalAvailability: { Dependencies.loadLocalAvailability() },
            loadRetryQueue: { FileRetryQueueStore().load() },
            loadBackupContext: {
                let (config, _, manifestStore) = try Dependencies.makeBackupDeps()
                let manifest = try await Dependencies.loadManifest(store: manifestStore)
                return (bucket: config.bucket, manifest: manifest)
            },
        )

        if json {
            let out = try formatDashboardJSON(data)
            FileHandle.standardOutput.write(out)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            StatusRenderer(isTTY: isatty(STDOUT_FILENO) != 0).render(data)
        }
    }

    /// Assemble ``DashboardData`` from injected loaders. An unconfigured
    /// install (`CLIError.notInitialized` from the migration guard or the
    /// backup context) degrades to library-only data instead of failing,
    /// so `status` works before `attic init`.
    static func buildDashboard(
        ensureMigrated: () async throws -> Void,
        loadAssets: () async throws -> [AssetInfo],
        loadLocalAvailability: () -> (any LocalAvailabilityProviding)?,
        loadRetryQueue: () -> RetryQueue?,
        loadBackupContext: () async throws -> (bucket: String, manifest: Manifest),
    ) async throws -> DashboardData {
        do {
            try await ensureMigrated()
        } catch CLIError.notInitialized {
            // No config — the backup/S3 section below degrades the same way.
        }

        let assets = try await loadAssets()
        let library = StatusStats.computeLibraryStats(assets)
        let types = StatusStats.computeUTIBreakdown(assets)
        let localAvailability = loadLocalAvailability()
        let retry = StatusStats.computeRetryInfo(loadRetryQueue())

        var backup: BackupStats?
        var s3: S3Info?

        do {
            let (bucket, manifest) = try await loadBackupContext()
            backup = StatusStats.computeBackupStats(
                assets: assets,
                manifest: manifest,
                localAvailability: localAvailability,
            )
            s3 = StatusStats.computeS3Info(bucket: bucket, manifest: manifest)
        } catch CLIError.notInitialized {
            // No config — show library only with init hint
        }

        return DashboardData(
            version: AtticCore.version,
            library: library,
            backup: backup,
            s3: s3,
            types: types,
            retry: retry,
        )
    }
}
