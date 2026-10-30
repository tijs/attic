# Attic 1.0.0-beta.26 release candidate notes

Unreleased. PRs #15–#17 are merged. Restore PR #18 remains draft until positive
Photos import, returned IDs and completed-import resume pass in the disposable
library. Publish these notes only after that gate, final CI and artifact checks.

- Completes backup JSONL/migration regression coverage and records current PTY,
  signal, cancellation and renderer evidence for [issue #13](https://github.com/tijs/attic/issues/13)
  in [PR #15](https://github.com/tijs/attic/pull/15).
- Requires [Ladder 0.7.0](https://github.com/tijs/ladder/releases/tag/v0.7.0),
  source `e48e8e800596bbb7529cd6b279bd76cf5dbc3f7a`, for old/macOS 27 album
  relationship discovery. [PR #16](https://github.com/tijs/attic/pull/16) adds
  Attic metadata integration coverage and a reproducible Package.resolved.
  Swift 6.1 and macOS 14 minimums remain unchanged. Real copied macOS 27 Photos
  databases have not been validated.
- Adds independent filesystem backup profiles on local APFS/HFS+ volumes for
  [issue #4](https://github.com/tijs/attic/issues/4),
  [PR #17](https://github.com/tijs/attic/pull/17). Missing/replaced external drives
  and internal mount placeholders fail safely; originals publish atomically
  after verification. Existing default S3 configuration/state remains compatible.
  New targets isolate manifest, retry and export state. See
  [filesystem backups](filesystem-backups.md) for supported filesystems and limits.
- Adds streamed, SHA-256-verified, resumable original-file recovery, UTC date/type/
  album selection, private sidecars/journal, explicit archive retrieval and a
  separately selected Photos import phase for
  [issue #8](https://github.com/tijs/attic/issues/8). Recovery does not require
  PhotoKit or identity migration, and never overwrites different local files.
  Archive requests require an explicit flag; uncertain Photos imports require
  explicit retry. See [restore](restore.md) for the full contract.
- Restore destinations must have directory trees disjoint from filesystem
  backups, including ancestor destinations. Journal updates use atomic
  per-resource records; unchanged completions write no journal data. Existing
  journals upgrade once. Keep `.attic-restore.json` and `.attic-restore-records/`
  together; older Attic versions cannot resume upgraded journals.
- Photos import subprocesses have bounded output, a two-minute deadline and
  cancellation-safe cleanup. The exact system Syndication auxiliary database
  may coexist with the explicitly selected primary library; another primary
  library still fails selection.

Recovery covers every resource represented in a manifest. Missing Live Photo
motion resources and edit history cannot be reconstructed. Photos import does
not rebuild database IDs, albums or complete library state.

The integrated source passes 392 local tests, the optimized build and formatting
checks. Synthetic PNG/MOV files restore with matching SHA-256 hashes, selection
filters and safe resume. Real disposable Photos selection, timeout cleanup,
cancellation and refusal of uncertain retries pass; **successful import, returned
IDs and completed-import resume remain unverified**. Archive transport and Photos
orchestration also have fixture/mock coverage. Live archive-provider behavior
and physical unplug/power-loss experiments remain untested. See
[validation evidence](validation/issue-8.md). No release or version bump is
performed by this draft.
