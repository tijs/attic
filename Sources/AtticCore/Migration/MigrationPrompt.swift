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

        If the original Mac is no longer available, see
        docs/migration-cloud-identity.md for recovery options.

        Run `attic migrate` to start (or `attic migrate --dry-run` to preview).

        """
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
