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

- `AtticCore` — shared library (public product): S3 client, manifest, config,
  keychain, metadata, backup/verify/refresh pipelines, AIMD concurrency
  controller, retry queue, unavailable-asset store, network monitor, viewer
  data store, thumbnailing. Designed for reuse by the CLI and a future macOS
  menu bar app — both consume `AtticCore` as an SPM library.
- `AtticCLI` — executable: ArgumentParser commands, terminal dashboard,
  Hummingbird-based viewer server, `LadderKitExportProvider` bridge.
- `AtticCoreTests` — tests using Swift Testing framework (178 tests).

Dependencies: `aws-signer-v4` (SigV4 signing for `URLSessionS3Client` — no full
AWS SDK), `swift-argument-parser`, `Hummingbird` (viewer), and `LadderKit`
pinned to `0.5.1+` via `https://github.com/tijs/ladder.git`.

Platform: macOS 14+, Swift 6.x, Apple Silicon only.

## Architecture

The backup pipeline:
`Photos Library → LadderKit (PhotoKit + enrichment) → AssetInfo[] → BackupPipeline → (adaptive export + upload) → manifest update`

- **LadderKit** provides `PhotoLibrary` (PhotoKit), `PhotosDatabase`
  (Photos.sqlite enrichment), `PhotoExporter` (export + SHA-256 + AppleScript
  fallback), `LocalAvailabilityProviding` (local vs. iCloud split), and the
  `AdaptiveConcurrencyControlling` protocol.
- **AIMDController** (`Sources/AtticCore/AIMDController.swift`) is attic's
  implementation of the adaptive controller. Observation-only: the exporter
  polls `currentLimit()` and reports `ExportOutcome` via `record(_:)`. Policy
  is additive-increase / multiplicative-decrease over a sliding 20-outcome
  window. Permanent failures (`.permanentlyUnavailable`) are ignored — not a
  lane-health signal. Local-only assets run at full `maxConcurrency`; iCloud
  assets are gated by the controller.
- **RetryQueue** (`retry-queue.json` on S3) — UUIDs of assets that failed in a
  previous run, with attempts/classification/first-seen/last-seen/message per
  entry. Merged across runs; unattempted entries are preserved when `--limit`
  cuts a run short. Retried first on the next run.
- **UnavailableStore** (`unavailable-assets.json` on S3) — shared-album or
  otherwise permanently-unreachable assets. Never auto-cleared — skip-forever.
- **S3 key format** — originals: `originals/{year}/{month}/{uuid}.{ext}`,
  metadata: `metadata/assets/{uuid}.json`.
- **Manifest** (`manifest.json` on S3) — maps UUID →
  `{ s3Key, checksum, backedUpAt }`. S3 is the single source of truth. Saved
  at batch boundaries during backup.
- **Network pause/resume** — `NetworkMonitoring` (backed by `NWPath`) detects
  network loss mid-upload; the upload loop waits and resumes from the retry
  set.
- **Staging reuse** — `StagingReclaim` finds previously-exported files on disk
  and reuses them instead of re-exporting (saves PhotoKit round-trips on
  resume).

All external dependencies are behind protocols (`S3Providing`, `ManifestStoring`,
`ConfigProviding`, `KeychainProviding`, `ExportProviding`, `NetworkMonitoring`,
`ThumbnailProviding`) for testability.

## CLI Commands

| Command | Description |
|---------|-------------|
| `status` | Library stats, backup progress, S3 manifest info |
| `backup` | Back up photos/videos to S3 |
| `verify` | Verify S3 objects against manifest |
| `refresh-metadata` | Re-upload metadata JSON |
| `rebuild` | Rebuild manifest from S3 metadata |
| `viewer` | Browse backed-up library in local web UI |
| `init` | Interactive S3 setup |

## Testing Patterns

Tests use mock implementations — never external services or credentials:

- `MockS3Provider` — in-memory actor-backed `[String: Data]` (ships in `AtticCore`)
- `MockExportProvider` — returns canned export results
- `TimeoutExportProvider` — simulates batch timeouts + deferred retry
- `MockNetworkMonitor` — simulates network up/down for pause-resume tests

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

## Design Context

### Users
Photo-enthusiast developers — people at the intersection of "comfortable running
S3 infrastructure" and "cares deeply about their photo library." They use Attic
to verify and browse their backed-up iCloud Photos library through a local web
viewer.

### Brand Personality
**Precise, trustworthy, quiet.** Attic fades into the background and just works.
Every element serves a purpose — nothing decorative, nothing performative.

### Aesthetic Direction
- **Tone:** Confident and precise — like a well-made instrument.
- **References:** Transmit/Panic apps (detail-obsessed, personality without
  frivolity), Linear/Raycast (fast, minimal chrome, every pixel earned).
- **Anti-references:** No generic dark SaaS (blue-on-dark card grids). No dev
  dashboard aesthetics (no monospace, no terminal vibes in the web UI).
- **Theme:** Designer's choice — serve the "quiet, precise" personality.

### Design Principles
1. **Photos first** — Minimize chrome, maximize content.
2. **Earned trust** — Reliable, precise status and metadata. No vague states.
3. **Quiet confidence** — Hierarchy through spacing, weight, and restraint.
4. **Intentional details** — Small touches that reward attention.
5. **Not a prototype** — Handles empty states, loading, and edge cases.
