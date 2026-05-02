import ArgumentParser
import AtticCore
import Foundation
import LadderKit
@preconcurrency import Photos

struct MigrateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Migrate the manifest from device-local to cloud-stable identity (one-time).",
        discussion: """
        Run once on a Mac signed into the same iCloud Photos library that
        produced the existing backup. Re-keys the manifest and per-asset
        metadata JSONs from device-local PhotoKit identifiers to stable
        cloud identifiers so the backup can be recognized by attic on any
        Mac in the same library.

        Idempotent and resumable — safe to re-run if interrupted.
        """,
    )

    @Flag(name: .long, help: "Run without prompting for confirmation.")
    var yes: Bool = false

    @Flag(name: .long, help: "Show what would be migrated without writing to S3.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Reset any leftover staging key or stale lock from a prior partial run.")
    var repair: Bool = false

    @Flag(
        name: .long,
        help: "Bypass the resolver-anomaly guard. Use only after verifying iCloud Photos and PhotoKit access.",
    )
    var force: Bool = false

    @Flag(
        name: .long,
        help: "Emit the migration report as a single JSON object on stdout (suppresses progress output).",
    )
    var json: Bool = false

    func run() async throws {
        let runner = try await Dependencies.makeMigrationRunner()

        if !dryRun, repair {
            // Surface what's about to be cleared so the user catches the
            // "stale" lock that is actually a different Mac mid-flight.
            let summary = await (try? Dependencies.describeMigrationCleanupState()) ?? ""
            if !summary.isEmpty {
                print("Repair: pre-delete state:")
                print(summary)
            }
            try? await Dependencies.deleteMigrationStagingKey()
            try? await Dependencies.deleteMigrationLock()
            print("Repair: cleared manifest.v2.json staging key and migration.lock.")
        }

        let isV1 = try await runner.detectIsV1()
        guard isV1 else {
            print("Manifest is already v2 — nothing to migrate.")
            return
        }

        if !yes, !dryRun, !confirmInteractive() {
            print("Aborted.")
            throw ExitCode.failure
        }

        print("")
        let report = try await runner.run(dryRun: dryRun, force: force)
        if json {
            let data = try formatMigrationReportJSON(report, dryRun: dryRun)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print(formatMigrationReport(report, dryRun: dryRun), terminator: "")
        }
    }

    private func confirmInteractive() -> Bool {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            FileHandle.standardError.write(Data(
                "Error: non-interactive shell. Re-run with --yes to confirm migration.\n".utf8,
            ))
            return false
        }
        print("")
        print("Migrate manifest from device-local to cloud-stable identity?")
        print("  - Re-keys manifest entries from PhotoKit local IDs to iCloud-stable IDs")
        print("  - Rewrites per-asset metadata JSONs on S3")
        print("  - Backs up the v1 manifest as manifest.v1.json on S3")
        print("  - Original photo objects are NOT moved or re-uploaded")
        print("")
        print("Continue? [y/N] ", terminator: "")
        guard let line = readLine() else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "y" || trimmed == "yes"
    }
}
