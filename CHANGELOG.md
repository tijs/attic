# Changelog

## 0.2.1

Resilient batch exports — isolates slow iCloud downloads instead of failing
entire batches.

### Batch subdivision

- **Automatic retry on timeout** — when a ladder batch times out (e.g. due to
  iCloud downloads), the batch is split in half and each half retried
  recursively (max depth 3). Only the truly stuck assets end up as failures.
- **Retry hint** — summary now shows
  `Run attic backup again to retry failed
  assets.` when there are failures.

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
