# Changelog

## 1.0.0-beta.9

Hotfix for `1.0.0-beta.8`: `S3Paths.uuidPattern` and `s3KeyPattern`
rejected `PHCloudIdentifier.stringValue`, which contains colons
(observed shape: `<UUID>:<index>:<base64-ish>`). `attic migrate`
aborted at the metadata-rewrite step with `Unsafe UUID for S3 key:
…`. Both patterns now allow `:` while still rejecting `/` so cloud
IDs cannot escape the `metadata/` or `originals/` prefix.

If you hit this on beta.8, run `attic migrate --repair` after
upgrading to clear the leftover staging key and stale lock, then
re-run `attic migrate`. The pre-migration manifest is still safe
on S3 as `manifest.v1.json`.

## 1.0.0-beta.8

Cloud-stable identity migration. The on-S3 manifest and per-asset metadata
JSONs are re-keyed from device-local PhotoKit identifiers to
`PHCloudIdentifier` so the same backup can be recognized by attic running
on any Mac signed into the same iCloud Photos library. Run `attic migrate`
once on the Mac that originally produced the backup.

### Identity model
- `Manifest` v2: per-entry `identityKind` (`.cloud` or `.local`) and
  `legacyLocalIdentifier`. v1 manifests decode without these fields and
  default to `.local`. Tampered or future identityKind values fall back to
  `.local` rather than failing the whole manifest decode.
- `RetryQueue` and `UnavailableAssets` carry `legacyLocalIdentifier` for
  forensics after re-keying.
- `manifest.v1.json` is preserved on S3 as a recovery snapshot before the
  swap. `manifest.v2.json` is a temporary staging key, deleted after a
  clean swap.
- Cross-machine migration coordination via `migration.lock` (TTL = 30
  minutes). Concurrent `attic migrate` invocations on a second Mac fail
  loudly; stale locks are reclaimable with `attic migrate --repair`.

### Safety
- Resolver-anomaly guards: migration aborts before any v2 write if PhotoKit
  returns 0 cloud identifiers for the library, or if at least 95% of
  entries fall back to `.local`. The likely root cause is iCloud Photos
  disabled or PhotoKit consent revoked. `attic migrate --force` overrides
  the guard once the user has manually verified the environment.
- LadderKit `PhotoKitCloudIdentityResolver` now requests `.readWrite`
  authorization explicitly (required by `cloudIdentifierMappings`).
- Local retry-queue and unavailable-store mutations only happen *after* the
  S3 manifest swap. A failed swap leaves both stores at v1, so a retry
  starts cleanly.
- `rewriteMetadataPayload` keeps unknown / future / Deno-written keys
  verbatim — only identity fields are touched.
- Re-key collisions (two old uuids → same cloud id) now keep the most
  recently backed-up entry and emit the loser's old uuid in the report so
  the runner deletes its orphaned metadata key.
- Tolerant identityKind decode: a bad row no longer takes down the whole
  manifest.

### Breaking changes
- `S3Providing.deleteObject(key:)` is now part of the protocol. External
  conformers built against earlier betas inherit a default extension impl
  that throws `S3OperationError.unsupported` so they continue to compile,
  but should override the method to participate in migration cleanup.
- Older attic binaries (1.0.0-beta.7 and earlier) cannot read v2 manifests.
  Do not downgrade without restoring `manifest.v1.json` first.

### Commands
- `attic migrate` (new) — interactive, with `--yes`, `--dry-run`,
  `--repair`, and `--force` flags.
- All other commands ensure the manifest is migrated before running, with
  a default-N auto-migrate prompt for safety in piped/CI contexts.

## 1.0.0-beta.7

Architectural cleanup, security hardening, and pipeline simplification. No
behavior changes for the golden path.

### Architecture
- `RetryQueue`: dropped the legacy `failedUUIDs: [String]` decoder and the
  custom `Codable` conformance. Uses compiler-synthesized coding now.
- `BackupPipeline`: extracted `filterPending`, `exportBatchWithFallback`, and
  `finalizeBackup` helpers so `runBackup` reads top-to-bottom. Removed the
  dead `ExportProviderError.isPermission` catch — permission is a pre-flight
  check, never raised during `exportBatch`.
- `BackupUpload`: network-pause retry is now a loop instead of recursion.
  No more stack-depth coupling with `maxPauseRetries`.
- `BackupOptions`: removed `saveInterval`. The manifest now saves at batch
  boundaries, which is simpler and survives crashes just as well.
- Check `ExportClassification` directly everywhere instead of the legacy
  `ExportError.unavailable` boolean.
- Removed the `normalizeUUID(...)` defensive splits in attic — LadderKit
  preserves caller-provided UUIDs at source now (no more `UUID/L0/001`
  leakage), so the splits were dead code.
- File renames: `AdaptiveConcurrency.swift` → `AIMDController.swift` (matches
  the type it holds), `BackupConstants.swift` → `DateFormatting.swift`.

### Security
- `attic init` fails closed if `tcgetattr`/`tcsetattr` can't disable terminal
  echo (e.g. stdin isn't a TTY). Previously, a piped/redirected stdin would
  read the secret in plaintext and could leak it to the screen or a tee'd
  log.
- Viewer `Content-Security-Policy` is now scoped to the configured S3
  endpoint host instead of hardcoded `*.amazonaws.com`. Custom endpoints
  (R2, Backblaze, MinIO) no longer rely on a permissive fallback.
- Viewer presigned-URL lifetime cut from 4h to 1h.
- `URLSessionS3Client` rejects bucket names containing a dot when
  `pathStyle = false` — AWS's virtual-hosted TLS cert only covers one label,
  so these requests would fail at connect time with a confusing cert error.
- Staging directory created with `0o700` so other local users can't read
  in-flight plaintext copies of the user's photos.

### Performance
- `ViewerDataStore` load path: parse year from the `YYYY-` prefix instead of
  allocating a `Date.ISO8601FormatStyle` per asset. Noticeable on large
  libraries.
- `URLSessionS3Client` bumps `httpMaximumConnectionsPerHost` from the default
  6 to 32 so the bounded upload group isn't re-serialized at the socket
  layer.
- Per-asset metadata uploads drop `.prettyPrinted` JSON formatting — ~40%
  smaller payloads. Manifest, config, and retry-queue stay pretty-printed
  (user-inspected).

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
- `attic status` now surfaces the pending-asset lane split (local vs iCloud)
  and a retry-queue summary (count, max attempts, oldest firstFailedAt).
- Retry queue schema upgrade: each entry now tracks `classification`,
  `attempts`, `firstFailedAt`, `lastFailedAt`, and `lastMessage`. Merging
  across runs preserves `firstFailedAt` and increments `attempts`, so the
  UI can surface how long an asset has been stuck. The legacy
  `failedUUIDs: [String]` payload decodes transparently — existing stores
  are upgraded on next write.
- **Retry queue no longer loses unattempted UUIDs.** When `--limit` cut a
  run short, a successful result would wipe the entire queue, including
  UUIDs that were never tried. The merge now keys on the attempted set:
  unattempted entries survive with their full history.
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
