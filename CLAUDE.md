# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What This Is

Swift CLI and shared library for backing up iCloud Photos to S3-compatible
storage. Part of the photo-cloud system (companion:
[ladder](https://github.com/tijs/ladder)).

## Commands

```bash
swift build 2>&1 | xcsift     # Build
swift test 2>&1 | xcsift      # Run all tests
swift build -c release 2>&1 | xcsift  # Release build
```

Run a single test by name:

```bash
swift test --filter "testName" 2>&1 | xcsift
```

## Package Structure

Swift package with three targets:

- `AtticCore` — shared library: S3 provider, manifest, config, keychain,
  metadata, backup/verify/refresh pipelines. Used by both CLI and menu bar app.
- `AtticCLI` — executable: ArgumentParser commands, terminal renderer
- `AtticCoreTests` — tests using Swift Testing framework

Dependencies: `aws-sdk-swift` (AWSS3), `swift-argument-parser`, `LadderKit`
(path dependency from `../ladder`).

Platform: macOS 14+, Swift 6.x, Apple Silicon only.

## Architecture

The backup pipeline:
`Photos Library → LadderKit (PhotoKit + enrichment) → AssetInfo[] → BackupPipeline → S3 upload → manifest update`

- **LadderKit** provides `PhotoLibrary` (PhotoKit), `PhotosDatabase`
  (Photos.sqlite enrichment), and `PhotoExporter` (export with SHA-256 hashing +
  AppleScript fallback for iCloud-only assets). Called directly as a library.
- **S3 key format** — originals: `originals/{year}/{month}/{uuid}.{ext}`,
  metadata: `metadata/assets/{uuid}.json`
- **Manifest** (`manifest.json` on S3) — maps UUID →
  `{ s3Key, checksum, backedUpAt }`. S3 is the single source of truth. Saved to
  S3 every 50 assets during backup.

All external dependencies are behind protocols (`S3Providing`, `ManifestStoring`,
`ConfigProviding`, `KeychainProviding`, `ExportProviding`) for testability.

## CLI Commands

| Command | Description |
|---------|-------------|
| `scan` | Scan Photos library, show summary |
| `status` | Show backup progress vs manifest |
| `backup` | Back up photos/videos to S3 |
| `verify` | Verify S3 objects against manifest |
| `refresh-metadata` | Re-upload metadata JSON |
| `rebuild` | Rebuild manifest from S3 metadata |
| `init` | Interactive S3 setup |

## Testing Patterns

Tests use mock implementations — never external services or credentials:

- `MockS3Provider` — in-memory `[String: Data]`
- `MockExportProvider` — returns canned export results
- `TimeoutExportProvider` — simulates batch timeouts + deferred retry

Uses Swift Testing framework (`@Test`, `#expect`, `@Suite`).

## Reference Docs

- [Architecture](docs/architecture.md) — pipeline, reader, manifest, interfaces
- [Asset Metadata](docs/metadata.md) — per-asset JSON schema uploaded to S3

## Releasing

1. Bump `AtticCore.version` in `Sources/AtticCore/AtticCore.swift`
2. Commit, tag with `v{version}`, push both main and the tag
3. The `Release` GitHub Action builds the binary and creates a GitHub release
4. Update `tijs/homebrew-tap` formula with new version and sha256 from the
   release checksums

## Conventions

- Files should stay under 500 lines
- Use LadderKit's `AssetKind` constants, not magic numbers
- S3 keys and UUIDs are validated with regex before interpolation (path
  traversal prevention)
- All dependencies injected via protocols
- Swift 6 strict concurrency — all types are `Sendable` where needed
