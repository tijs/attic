import AtticCore
import Foundation

/// Guard that runs at the top of every command needing a v2 manifest.
/// Detects v1 and pending thumbnail cleanup; prompts the user (TTY), runs
/// migration with progress, or fails fast on non-TTY with a clear
/// next-step message. Fast-paths to a no-op when both phases are already
/// applied.
///
/// Collaborators are injected so the control flow and output routing are
/// testable without real S3, config, or PhotoKit —
/// `Dependencies.ensureManifestMigrated` wires the live set. Prompts and
/// error hints go to `emitPrompt` (stderr in production); progress lines
/// and completion summaries go to `emitStatus`, which JSON-mode commands
/// route to stderr so stdout stays reserved for machine-readable output.
struct MigrationGuard: Sendable {
    /// Load the current manifest from S3.
    var loadManifest: @Sendable () async throws -> Manifest
    /// Build a fully-wired migration runner reporting through the handler.
    var makeRunner: @Sendable (@escaping MigrationRunner.ProgressHandler) async throws -> MigrationRunner
    var isTTY: Bool
    var readAnswer: @Sendable () -> String?
    /// Sink for prompts and error hints — stderr in production.
    var emitPrompt: @Sendable (String) -> Void
    /// Sink for progress lines and completion summaries — stdout for human
    /// invocations, stderr when stdout carries JSON (`status --json`).
    /// A trailing newline is appended by the sink.
    var emitStatus: @Sendable (String) -> Void

    func ensureMigrated() async throws {
        let manifest = try await loadManifest()

        let needsV1 = manifest.isV1
        let needsCleanup = !manifest.thumbnailsCleanupApplied
        guard needsV1 || needsCleanup else { return }

        // v1 path keeps its existing pre-runner prompt. The runner detects
        // and runs cleanup in the same invocation, so no second prompt is
        // needed up-front for a v1+cleanup-pending bucket — the runner's
        // confirm closure handles it.
        if needsV1 {
            emitPrompt(MigrationPrompt.message(count: manifest.entries.count))
            let decision = MigrationPrompt.decide(
                isTTY: isTTY,
                answer: { isTTY ? readAnswer() : nil },
            )
            switch decision {
            case .nonInteractive:
                emitPrompt(MigrationPrompt.nonInteractiveHint)
                throw CLIError.migrationRequired
            case .abort:
                throw CLIError.migrationRequired
            case .proceed:
                break
            }
        }

        let emitStatus = emitStatus
        let runner = try await makeRunner { msg in emitStatus("  \(msg)") }
        let confirmCleanup: MigrationRunner.CleanupConfirmHandler = { [isTTY, emitPrompt, readAnswer] count, bytes in
            guard isTTY else { return .nonInteractive }
            emitPrompt(MigrationPrompt.cleanupMessage(count: count, totalBytes: bytes))
            switch MigrationPrompt.decideCleanup(isTTY: isTTY, answer: { readAnswer() }) {
            case .proceed: return .proceed
            case .abort: return .abort
            case .nonInteractive: return .nonInteractive
            }
        }

        let report: MigrationReport
        do {
            report = try await runner.run(confirmCleanup: confirmCleanup)
        } catch let MigrationRunnerError.thumbnailCleanupNonInteractive(count, bytes) {
            emitPrompt(
                "\nattic detected \(count) orphaned thumbnails (\(bytes) bytes) under " +
                    "`thumbnails/` and needs to delete them. Re-run from an interactive shell " +
                    "to confirm.\n",
            )
            throw CLIError.migrationRequired
        } catch MigrationRunnerError.thumbnailCleanupDeclined {
            throw CLIError.migrationRequired
        } catch let MigrationRunnerError.thumbnailCleanupPartial(deleted, failed) {
            emitPrompt(
                "\nThumbnail cleanup partially failed: \(deleted) deleted, " +
                    "\(failed.count) failed. Re-run to retry.\n",
            )
            throw CLIError.migrationRequired
        }

        emitStatus("")
        if needsV1 {
            emitStatus("Migration complete: \(report.cloudMigrated) cloud, \(report.localFallback) local fallback.")
        }
        if report.thumbnailsDeleted > 0 {
            let mb = Double(report.thumbnailsBytes) / (1024 * 1024)
            emitStatus("  Thumbnails cleanup: \(report.thumbnailsDeleted) deleted (\(String(format: "%.1f", mb)) MB).")
        }
        emitStatus("")
    }
}
