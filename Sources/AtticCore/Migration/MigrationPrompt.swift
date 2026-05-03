import Foundation

/// Pure helpers for the auto-migrate prompt. Extracted so test code can
/// exercise the decision logic without driving stdin/stdout, and so the CLI
/// auto-gate can share the same behavior as `attic migrate` interactive
/// confirmation.
public enum MigrationPrompt {
    /// Outcome of evaluating a user's response to the migration prompt.
    public enum Decision: Equatable, Sendable {
        /// User affirmatively answered yes — run the migration.
        case proceed
        /// User declined or gave any non-yes input — do not migrate.
        case abort
        /// Shell is non-interactive (piped, CI). Caller should print a hint
        /// and exit rather than silently proceeding or aborting.
        case nonInteractive
    }

    /// Hint emitted to stderr in non-interactive contexts. Tells the user how
    /// to perform the migration explicitly.
    public static let nonInteractiveHint = """
    Re-run `attic migrate --yes` from an interactive shell on the Mac that \
    originally produced the backup to perform the migration.

    """

    /// Body of the v1-detected message. Caller writes this to stderr.
    public static func message(count: Int) -> String {
        """

        attic detected a v1 manifest (\(count) entries) keyed by device-local
        PhotoKit identifiers. attic now uses cross-device cloud identifiers
        so the same backup is recognized on every Mac in your iCloud Photos
        library. A one-time migration is needed before this command can run.

        Important: the migration must run on the Mac that originally created
        the backup. PhotoKit local IDs are per-device, so a different Mac
        cannot translate them to cloud IDs. If you run the migration here
        and this is not that Mac, attic will detect the mismatch and abort
        before changing anything.

        Estimated runtime: \(runtimeEstimate(entryCount: count)). The CLI
        prints "Rewrote N/total metadata JSONs…" every 250 entries, so a
        long migration is not hung — give it time.

        If the original Mac is no longer available, see
        docs/migration-cloud-identity.md for recovery options.

        Run `attic migrate` to start (or `attic migrate --dry-run` to preview).

        """
    }

    /// Friendly runtime estimate based on entry count. Migration's hot path
    /// is per-asset metadata-JSON rewrite (4 S3 round trips each, parallelism
    /// 16). On a residential link to a B2/R2/Wasabi-class endpoint, observed
    /// throughput is ~15–45 entries/sec (27k library = 10–30 min). The range
    /// covers fast (low-latency, well-peered) and slow (overseas, lossy)
    /// endpoints. Tiny libraries collapse to "under a minute".
    public static func runtimeEstimate(entryCount: Int) -> String {
        guard entryCount > 0 else { return "under a minute" }
        let fastSeconds = Double(entryCount) / 45.0
        let slowSeconds = Double(entryCount) / 15.0
        // Short-circuit on actual seconds before rounding to minutes — the
        // 30–59s band would otherwise round up to "up to ~1 minute" and
        // sit awkwardly next to the literal "under a minute" branch.
        if slowSeconds < 60 { return "under a minute" }
        let fastMinutes = Int((fastSeconds / 60.0).rounded())
        let slowMinutes = Int((slowSeconds / 60.0).rounded())
        if fastMinutes < 1 { return "up to ~\(slowMinutes) minute\(slowMinutes == 1 ? "" : "s")" }
        return "roughly \(fastMinutes)–\(slowMinutes) minutes"
    }

    /// Decide whether to proceed, abort, or fail with a non-interactive hint.
    ///
    /// Defaults to **abort on empty input** so a piped stdin (CI, agent
    /// harness without explicit answer) cannot accidentally commence a
    /// one-shot data migration. The explicit `attic migrate` command is the
    /// supported way to opt in. This matches the default-N posture of the
    /// `attic migrate` confirmation prompt — the two surfaces always agree.
    public static func decide(isTTY: Bool, answer: () -> String?) -> Decision {
        guard isTTY else { return .nonInteractive }
        let raw = (answer() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw == "y" || raw == "yes" { return .proceed }
        return .abort
    }
}
