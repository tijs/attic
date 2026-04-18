# Changelog

## 1.0.0-beta.6

Adaptive export: separate local-cache and iCloud lanes, with the iCloud lane
throttled by an AIMD controller when PhotoKit pushes back.

- `AIMDController` (in AtticCore) — additive-increase / multiplicative-decrease
  concurrency policy with a sliding 20-outcome window. Backs off the limit by
  half when the transient-failure rate exceeds 30%, grows it by 1 when the
  rate drops to 5% or below, and clears the window on every limit change so
  stale pre-change outcomes don't immediately re-trigger.
- `BackupCommand` wires `PhotosDatabaseLocalAvailability` (from Photos.sqlite's
  `ZLOCALAVAILABILITY` flag) + an `AIMDController` into the exporter. Local
  assets run at full `maxConcurrency`; iCloud assets are gated by the
  controller.
- `BackupProgressDelegate.concurrencyChanged(limit:)` — new delegate callback
  emitted between batches whenever the controller adjusts.
- Terminal dashboard shows the current lane count next to upload speed.
- Retry queue schema upgrade: each entry now tracks `classification`,
  `attempts`, `firstFailedAt`, `lastFailedAt`, and `lastMessage`. Merging
  across runs preserves `firstFailedAt` and increments `attempts`, so the
  UI can surface how long an asset has been stuck. The legacy
  `failedUUIDs: [String]` payload decodes transparently — existing stores
  are upgraded on next write.
- `BackupUpload` now normalizes PhotoKit's full-path identifiers
  (`UUID/L0/001`) to bare UUIDs before appending to `report.errors`, so
  the retry-first partition actually matches failed assets on the next
  run.
- Bumps LadderKit dependency to 0.5.0 for adaptive export and local
  availability APIs.

## 1.0.0-beta.5

- **Shared-album unavailable tracking** — assets in iCloud Shared Albums whose
  derivative has failed server-side are detected, marked as unavailable, and
  skipped on subsequent backups instead of being retried forever
- **Persistent unavailable store** — records live at
  `~/.attic/unavailable-assets.json` with attempt counts and last-failure
  reason; entries are never auto-cleared (unlike the retry queue)
- Bumps LadderKit dependency to 0.4.0 for the new `isShared` and
  `ExportError.unavailable` APIs

## 1.0.0-alpha.2

Animated preparation spinner for the backup command.

- **Preparation spinner** — shows an animated spinner with status messages
  ("Loading manifest from S3...", "Scanning Photos library...") during the
  preparation phase before uploads begin, so the CLI no longer appears hung
- **Unused variable fix** — removed unused `config` binding in backup command

## 0.2.6

Hardened error detection and timeout handling.

- **Structured permission detection** — detect ladder permission errors via exit
  code 77 instead of string-matching stderr text
- **Increased base timeout** — subprocess timeout raised from 5 to 10 minutes to
  match ladder's per-asset AppleScript timeout, preventing premature kills during
  iCloud downloads

Compatible with ladder v0.3.3.

## 0.2.5

Support for ladder v0.3.0 — iCloud-only asset export via AppleScript fallback.

- **Permission error detection** — when ladder reports a missing Automation
  permission, attic aborts immediately with a clear message instead of retrying
  every batch
- **Updated init output** — `attic init` now lists all required permissions
  (Photos, Full Disk Access, Automation)
- **iCloud-only error context** — export errors for iCloud-only assets now note
  that the AppleScript fallback was attempted
- Updated architecture docs to reflect ladder's AppleScript fallback
- Updated unattended backup guide with Automation permission setup

Compatible with ladder v0.3.0.

## 0.2.4

Review fixes: type safety, error handling, cleanup.

- `LadderTimeoutError` class replaces regex-based timeout detection
- `Exporter` interface now includes optional `setEstimatedBatchBytes`
- Staging directory created once per exporter, not per subprocess
- Guard against negative byte estimates in timeout calculation
- CLI `--version` now reports correct version

## 0.2.3

Skip slow assets, finish the rest, retry later.

### Skip-and-defer

- **Individual retry on batch timeout** — when a batch times out, each asset is
  retried individually to find the slow one(s). Fast assets proceed immediately;
  slow ones are deferred.
- **Deferred retry** — assets that timed out individually are retried with a
  longer timeout after all remaining batches complete.
- **Clear feedback** — you see exactly which file is slow:
  ```
  Batch 1/2  (37 photos, 13 videos, ~1.6 GB)
    Batch timed out — retrying 50 assets individually...
    Deferring BIG_VIDEO.MOV (video, 450.2 MB) — timed out, will retry after remaining batches
  ```
- **Size-scaled timeouts** — 5 min base + 1 min per 100 MB of estimated batch
  size.
- **Sorted batches** — photos first (by size), then videos (by size).
- **Retry hint** — summary shows
  `Run attic backup again to retry failed
  assets.` when there are failures.

## 0.2.2

Better debugging and smarter timeouts for large batches. Superseded by 0.2.3.

## 0.2.1

Batch subdivision on timeout. Superseded by 0.2.3.

## 0.2.0

Manifest stored on S3. Compatible with ladder v0.2.0.

### Manifest on S3

- **S3 is the single source of truth** for the backup manifest — no local file
  needed. Enables cross-machine and cross-app (CLI ↔ menu bar app) continuity.
- **Automatic migration** — existing local manifests at `~/.attic/manifest.json`
  are uploaded to S3 on first run.
- **Crash resilience** — manifest is saved to S3 every 50 assets during backup.
- **Simplified force-quit** — second Ctrl+C exits immediately; progress is saved
  up to the last checkpoint (uploads are idempotent).
- **Status command now reads from S3** — requires S3 credentials (same as
  backup).

### Other

- Compatible with ladder v0.2.0 (no protocol changes needed).

## 0.1.6

Resilient backup pipeline — fixes Ctrl+C not working and adds sleep/wake
recovery.

### Signal handling

- **AbortController-based cancellation** — first Ctrl+C gracefully cancels
  in-flight operations (ladder subprocess, S3 uploads), saves manifest, and
  exits. Second Ctrl+C force-quits immediately with emergency manifest save.
- **Subprocess timeout** — ladder process killed after 5 minutes if stuck.
- **Abort-aware retry** — backoff delays interrupted immediately on Ctrl+C.

### Network resilience

- **Retry with exponential backoff** on transient S3 failures (timeout,
  ECONNRESET, etc.) — handles sleep/wake recovery automatically.
- **Per-request S3 timeouts** scaled by body size (2 min base + ~500 KB/s) so
  large video uploads don't time out while dead connections still get caught.
- **Retry added to verify and refresh-metadata** commands too.

### Cleanup

- Staged files now cleaned up via `finally` block — no more orphans on
  interruption.
- Shared `withRetry` utility and `AbortError` class extracted for reuse.
- `ManifestStore` exposes `filePath` for reliable emergency saves.
- 11 new tests (retry, subprocess racing).

## 0.1.0

Initial release.

- **scan** — Scan Photos library and show statistics (asset counts, sizes,
  types, local vs iCloud-only)
- **status** — Compare Photos DB against backup manifest to show backed up vs
  pending
- **backup** — Export originals via ladder and upload to S3 with per-asset
  metadata JSON
- **verify** — Check backup integrity (quick HEAD check or deep SHA-256
  re-verification)
- **init** — Interactive setup for S3 endpoint, region, bucket, and Keychain
  credentials
- **refresh-metadata** — Re-upload metadata JSON for already backed-up assets

### Features

- Works with any S3-compatible provider (Scaleway, Hetzner, OVH, AWS, etc.)
- Config file at `~/.attic/config.json` with validation
- Credentials stored in macOS Keychain
- Rich metadata: albums, descriptions, keywords, people, edit detection
- Incremental backups via local manifest with atomic writes
- Manifest rebuild from S3 metadata
- Friendly error messages for common failures
- Installable via Homebrew (`brew install tijs/tap/attic`)
