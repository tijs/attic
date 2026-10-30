# Backup JSONL and terminal regression evidence

Issue: https://github.com/tijs/attic/issues/13
Implementation: https://github.com/tijs/attic/pull/14 (e7e72c8)

The follow-up regression in `MigrationGuardTests` runs the real migration guard,
cloud-identity migration runner, mock object store, backup pipeline and command
completion boundary together. The interactive case migrates an existing v1
entry and uploads a second original. It checks the final byte/count totals,
exactly one completion event, independently parseable JSONL, no ANSI or human
migration text on stdout, and preservation of the migrated entry. The
noninteractive case checks a fatal completion, the stderr hint/failure hook,
and preservation of the v1 manifest. Real Photos and S3 are not accessed.

The original failing terminal session was not captured. We retain that evidence
gap rather than manufacture a historical transcript. Re-running the old renderer
is not required for acceptance: current deterministic renderer tests and bounded
PTY subprocess tests exercise concurrent callbacks, changing dimensions, Unicode,
control characters, final output, input mode restoration and signal cancellation.
The original implementation is preserved at `e7e72c8^`; its first frame emits
nine rows, subsequent frames emit eight and final rendering always moves eight
rows. State locking did not serialize the multi-write frame itself. These are
source observations, not a captured user-session transcript.

Run `swift test`, `swiftformat --lint .` and `swiftlint lint --quiet` to repeat
validation. The migration test uses injected terminal/output adapters; the PTY
and signal suites launch the debug CLI executable.
