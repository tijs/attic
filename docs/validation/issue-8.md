# Restore validation for issue #8

Validation on 2026-10-30 against the combined issue stack, including restore
commit `c7a5363` (integrated head `48904c8`, same tree as validation `068c194`).

- All 392 Swift tests in 64 suites pass. SwiftFormat passes; SwiftLint exits
  successfully with existing warnings. The optimized build and restore help pass.
- Journal regressions measure actual staged bytes for 128 completions, enforce
  a constant per-record budget, and require zero journal writes on unchanged
  resume. Migration, failed publication, corrupt/foreign records and durable
  pending intent before importer effects are covered.
- Ancestor destinations are rejected before locking, permission changes or
  restore writes. Tests preserve both source data and destination contents.
- Native subprocess tests exercise nonzero exit status, timeout, cancellation,
  descendant cleanup, output limits, invalid encoding and missing executables.

## Disposable runtime fixture

The source contains only locally generated PNG and H.264 MOV media. A separate
named filesystem profile and recovery directory isolate all data and state.
The empty Photos library is copied from the MIT-licensed osxphotos repository,
revision `27c2f9d68e924770ecdc6cdc902d0737f3a16fee`, fixture
`tests/Test-Empty-Library-Ventura-13-5.photoslibrary`. Photos opens/upgrades this
copy; household Photos libraries are not used.

Actual CLI evidence:

- Backup verification: 2 OK, 0 missing, 0 errors.
- Date/exact-album/photo selection: 1 resource; corresponding video selection:
  1 resource.
- File-only resume: 0 recovered, 2 verified existing, 0 failed.
- Both recovered originals match the source media and journal SHA-256 hashes.
- The selected disposable database is the database opened by Photos. Selection
  also permits only the exact system Syndication auxiliary database alongside
  one primary library, never another primary or a similarly named library.
- A real import event reaches its 120-second deadline and advances to the next
  resource without hanging in subprocess cleanup. SIGINT during that next event
  exits promptly and reaps the AppleScript child. Durable uncertain/pending
  records remain on disk.
- Resume without explicit uncertain retry reports 2 uncertain resources and
  starts no AppleScript subprocess. Recovered originals remain valid.

## Open acceptance gate

The Photos AppleEvent does not complete on this host. The disposable library
still contains zero assets. Positive import, returned IDs and completed-import
duplicate/resume behavior are therefore **not validated**. Mock coverage does
not close this gap. PR #18 remains draft and issue #8 remains open pending that
runtime validation. No Attic release, version bump or Homebrew update is justified
by this evidence alone.

Archive status/request/polling contracts and native HTTP downloads have fixture
coverage. Live archive-provider behavior and physical drive unplug/power-loss
experiments have not been tested.
