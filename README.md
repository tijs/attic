<p align="center">
  <img src="attic-logo.png" width="128" alt="attic logo">
</p>

# Attic

Back up your iCloud Photos library to S3-compatible storage.

Attic reads your Photos library via PhotoKit, enriches metadata from
Photos.sqlite, exports originals with SHA-256 hashing, and uploads them to an
S3-compatible bucket. A manifest on S3 tracks what has already been backed up so
subsequent runs only upload new assets.

Uses [LadderKit](https://github.com/tijs/ladder) for PhotoKit access and
AppleScript fallback for iCloud-only assets.

Works with any S3-compatible provider. EU-friendly options include
[Scaleway](https://www.scaleway.com/en/object-storage/),
[Hetzner](https://www.hetzner.com/storage/object-storage), and
[OVH](https://www.ovhcloud.com/en/public-cloud/object-storage/).

## Install

### Homebrew (recommended)

```bash
brew install tijs/tap/attic
```

### From source (requires Swift 6.x, macOS 14+)

```bash
git clone https://github.com/tijs/attic.git
cd attic
swift build -c release
sudo cp .build/release/AtticCLI /usr/local/bin/attic
```

## Prerequisites

- macOS 14+ (Sonoma), Apple Silicon
- An S3-compatible storage bucket and API credentials

## Permissions

On first run, macOS will show permission dialogs for:

- **Photos library access** — required to read your photo/video assets
- **Keychain access** — required to read stored S3 credentials

Both are one-time prompts. Click "Allow" or "Always Allow" to proceed. These
permissions can be reviewed in System Settings → Privacy & Security.

## Setup

Run the interactive setup:

```bash
attic init
```

This prompts for your S3 endpoint, region, bucket name, and credentials. Config
is saved to `~/.attic/config.json` and credentials are stored in the macOS
Keychain.

## Commands

### init

Interactive setup — configure S3 connection and store credentials.

```bash
attic init
```

### scan

Scan the Photos library and print statistics (asset counts, types, favorites,
edits).

```bash
attic scan
```

### status

Compare the Photos library against the S3 manifest. Shows assets backed up vs
pending, broken down by local-cache vs iCloud-only lane, and a retry-queue
summary (count, max attempts, oldest first-failed timestamp).

```bash
attic status
```

### backup

Export pending assets and upload originals + metadata JSON to S3.

```bash
attic backup
```

| Flag                  | Description                                |
| --------------------- | ------------------------------------------ |
| `--dry-run`           | Show what would be uploaded without uploading |
| `--limit N`           | Stop after N assets (useful for test runs) |
| `--batch-size N`      | Assets per export batch (default: 50)      |
| `--type photo\|video` | Only back up photos or videos              |

During a backup, a live-updating terminal dashboard shows progress, speed,
current file, elapsed time, and the adaptive iCloud-lane concurrency limit.
Non-TTY output (pipes, CI) falls back to line-by-line progress.

Attic is crash- and network-resilient:

- **Adaptive iCloud throttling** — local-cache and iCloud-only exports run
  in separate lanes. The iCloud lane uses an AIMD controller (attic's
  `AIMDController` implementing LadderKit's `AdaptiveConcurrencyControlling`)
  to back off when Photos.app or iCloud pushes back, and to ramp up on a
  clean lane. See [Lanes and adaptive concurrency](docs/lanes-and-adaptive-concurrency.md)
  for details.
- **Retry queue** — transient failures are remembered on S3
  (`retry-queue.json`) and retried first on the next run, carrying
  attempts/first-seen/last-message for each UUID.
- **Permanent-unavailable store** — shared-album assets whose derivative has
  gone server-side (Photos.app error `-1728`) are recorded in
  `unavailable-assets.json` and skipped on subsequent runs.
- **Network pause/resume** — loss of connectivity pauses uploads instead of
  failing them. The manifest is saved before waiting so a long outage doesn't
  lose progress.
- **Staging reuse** — exported files left behind by an aborted run are
  re-used on the next run instead of re-exported from Photos.app.

### verify

Verify backup integrity by confirming every manifest entry exists in S3.

```bash
attic verify
```

| Flag              | Description                       |
| ----------------- | --------------------------------- |
| `--concurrency N` | Concurrent requests (default: 20) |

### refresh-metadata

Re-upload metadata JSON for already backed-up assets without re-uploading the
original files. Useful after adding new metadata fields.

```bash
attic refresh-metadata
```

| Flag              | Description                      |
| ----------------- | -------------------------------- |
| `--dry-run`       | Show what would be uploaded      |
| `--concurrency N` | Concurrent uploads (default: 20) |

### rebuild

Rebuild the manifest from S3 metadata files (disaster recovery).

```bash
attic rebuild
```

### viewer

Browse your backed-up library in a local web UI. Starts a localhost HTTP server
that loads metadata from S3 and serves a photo grid with filtering and lightbox.

```bash
attic viewer
```

| Flag       | Description                        |
| ---------- | ---------------------------------- |
| `--port N` | HTTP port (default: random unused) |

The viewer loads metadata progressively in the background — you can start
browsing immediately while the full library loads. Filters (year, album,
favorites, photo/video) update dynamically as metadata arrives.

## Configuration

Attic stores its configuration at `~/.attic/config.json`:

```json
{
  "endpoint": "https://s3.fr-par.scw.cloud",
  "region": "fr-par",
  "bucket": "my-photo-backup",
  "pathStyle": true,
  "keychain": {
    "accessKeyService": "attic-s3-access-key",
    "secretKeyService": "attic-s3-secret-key"
  }
}
```

The `keychain` section is optional and defaults to the service names shown
above. Credentials are always stored in the macOS Keychain, never in config
files or environment variables.

`scan` works without config (it only reads the Photos library). All other
commands require config and S3 credentials — run `attic init` if missing.

## Architecture

```
Photos Library → PhotoKit (LadderKit) → AssetInfo[]
                                           ↓
                               BackupPipeline (AtticCore)
                                   ↓              ↓
                             S3 upload      Manifest update
```

The project is a Swift package with three targets:

- **AtticCore** — shared library (public SPM product): S3 client
  (`URLSessionS3Client`, SigV4 via `aws-signer-v4` — no full AWS SDK),
  manifest, config, keychain, metadata, backup/verify/refresh pipelines,
  `AIMDController` (adaptive concurrency), `RetryQueue`, `UnavailableStore`,
  `NWPathNetworkMonitor`, viewer data store, and thumbnailing. Consumed by
  the CLI and designed for reuse by a future macOS menu bar app.
- **AtticCLI** — executable: ArgumentParser commands, terminal dashboard,
  Hummingbird-based viewer server, `LadderKitExportProvider` bridge.
- **AtticCoreTests** — 178 tests using the Swift Testing framework.

All external dependencies are behind protocols (`S3Providing`, `ManifestStoring`,
`ConfigProviding`, `KeychainProviding`, `ExportProviding`, `NetworkMonitoring`,
`ThumbnailProviding`) for testability.

## Development

```bash
swift build                    # Build
swift test                     # Run tests
swift build -c release         # Release build
swift test --filter "testName" # Run single test
```

Tests use dependency injection with mock implementations (MockS3Provider,
MockExportProvider) — no external services or credentials needed.

## Dependencies

- [LadderKit](https://github.com/tijs/ladder) (≥ 0.5.1) — PhotoKit access,
  Photos.sqlite enrichment, photo export with AppleScript fallback,
  local/iCloud lane partitioning, and the
  `AdaptiveConcurrencyControlling` protocol.
- [aws-signer-v4](https://github.com/adam-fowler/aws-signer-v4) — SigV4
  request signing. Attic ships a URLSession-based S3 client instead of the
  full AWS SDK (smaller binary, fewer transitive deps).
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) —
  CLI command parsing.
- [Hummingbird](https://github.com/hummingbird-project/hummingbird) — HTTP
  server for `attic viewer`.

## Documentation

- [Architecture](docs/architecture.md) — How attic works: the backup pipeline,
  photo library access, manifest lifecycle, and design boundaries
- [Lanes and adaptive concurrency](docs/lanes-and-adaptive-concurrency.md) —
  Why attic splits exports into local and iCloud lanes, and how the AIMD
  controller adapts to iCloud throttling
- [Asset Metadata](docs/metadata.md) — Schema reference for the per-asset JSON
  uploaded to S3
