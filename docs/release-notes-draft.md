# Attic release notes draft

Unreleased: review the separate PRs before choosing an Attic version or publishing.

- Completes backup JSONL/migration regression coverage and records current PTY,
  signal, cancellation and renderer evidence for [issue #13](https://github.com/tijs/attic/issues/13)
  in [PR #15](https://github.com/tijs/attic/pull/15). The historical failing
  terminal session was not captured; current deterministic/PTY regressions are
  the available evidence.
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

Recovery covers every resource represented in a manifest. Missing Live Photo
motion resources and edit history cannot be reconstructed. Photos import does
not rebuild database IDs, albums or complete library state. Archive transport and
Photos orchestration have fixture/mock coverage; positive import targeting in a
real disposable Photos library, live archive-provider behavior, and physical
unplug/power-loss experiments remain unverified. No release or version bump is
performed by this draft.
