# Changelog

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
