# Changelog

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

- **scan** — Scan Photos library and show statistics (asset counts, sizes, types, local vs iCloud-only)
- **status** — Compare Photos DB against backup manifest to show backed up vs pending
- **backup** — Export originals via ladder and upload to S3 with per-asset metadata JSON
- **verify** — Check backup integrity (quick HEAD check or deep SHA-256 re-verification)
- **init** — Interactive setup for S3 endpoint, region, bucket, and Keychain credentials
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
