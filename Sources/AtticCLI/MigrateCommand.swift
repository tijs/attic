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

    @Flag(name: .long, help: "Reset any leftover staging key from a prior partial run.")
    var repair: Bool = false

    func run() async throws {
        let runner = try await Dependencies.makeMigrationRunner()

        if !dryRun, repair {
            try? await Dependencies.deleteMigrationStagingKey()
            print("Cleared any leftover manifest.v2.json staging key.")
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
        let report = try await runner.run(dryRun: dryRun)
        printReport(report)
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

    private func printReport(_ report: MigrationReport) {
        if report.alreadyMigrated {
            print("Manifest is already v2.")
            return
        }
        print("──────────────────────────────────────")
        print("Migration report\(dryRun ? " (dry run)" : "")")
        print("  Total entries          \(report.totalEntries)")
        print("  Re-keyed to cloud id   \(report.cloudMigrated)")
        print("  Local fallback         \(report.localFallback)")
        if !report.unmapped.isEmpty {
            print("  Unmapped (deleted?)    \(report.unmapped.count)")
        }
        if !report.multipleFoundCollisions.isEmpty {
            print("  Multiple-found        \(report.multipleFoundCollisions.count) (review manually)")
        }
        if !report.rekeyCollisions.isEmpty {
            print("  Re-key collisions     \(report.rekeyCollisions.count)")
        }
        if !report.errors.isEmpty {
            print("  Transient errors       \(report.errors.count) (re-run to retry)")
        }
        if !dryRun {
            print("  Metadata JSONs rewritten  \(report.metadataRewritten)")
            if report.metadataMissing > 0 {
                print("  Metadata JSONs missing    \(report.metadataMissing)")
            }
        }
        print("")
    }
}
