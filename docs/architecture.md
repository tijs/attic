# Architecture

Attic reads the macOS Photos library via PhotoKit (through LadderKit), exports
original files, and uploads them to S3 with rich metadata. A manifest on S3
tracks progress so runs are incremental.

## System overview

```
PhotoKit ──→ LadderKit ──→ AssetInfo[] ──→ backup pipeline
  (read-only)    (PhotosDatabase enrichment)       │
                                                   ├─→ PhotoExporter (export + SHA-256)
                                                   │     originals to staging dir
                                                   │
                                                   ├─→ S3 upload (original + metadata JSON)
                                                   │
                                                   └─→ manifest.json (on S3, shared across machines)
```

Attic never modifies the Photos library. PhotoKit access is read-only.

## Reading the Photos library

LadderKit provides two components for reading the library:

**PhotoKitLibrary** — enumerates assets via PhotoKit's `PHAsset` API, returning
`AssetInfo` structs with core fields: UUID, filename, date, dimensions, GPS, UTI,
favorite status, media type.

**PhotosDatabase** — enriches assets by querying Photos.sqlite directly
(read-only). Seven independent queries each build a `Map` keyed by asset primary
key (Z_PK). During enrichment, each asset is populated from these maps with a
default of `nil` or `[]` if no match exists.

| Query              | Source tables                                              | Returns                    |
| ------------------ | ---------------------------------------------------------- | -------------------------- |
| Descriptions       | `ZASSETDESCRIPTION` → `ZADDITIONALASSETATTRIBUTES`         | `Map<number, string>`      |
| Albums             | `ZGENERICALBUM` → `Z_33ASSETS`                             | `Map<number, AlbumRef[]>`  |
| Keywords           | `ZKEYWORD` → `Z_1KEYWORDS` → `ZADDITIONALASSETATTRIBUTES` | `Map<number, string[]>`    |
| People             | `ZPERSON` → `ZDETECTEDFACE`                                | `Map<number, PersonRef[]>` |
| Edits              | `ZUNMANAGEDADJUSTMENT` → `ZADDITIONALASSETATTRIBUTES`      | `Map<number, EditInfo>`    |
| Rendered resources | `ZINTERNALRESOURCE` (resource type 1)                      | `Set<number>`              |

All enrichment queries go through `safeQuery()`, which catches "no such table"
errors silently and logs other failures. This makes the reader resilient across
macOS versions where table schemas may differ.

People are deduplicated per asset — a person appears at most once even if
detected in multiple face regions.

### Edit detection

An asset is considered edited (`hasEdit: true`) only when two conditions are
met:

1. An entry exists in `ZUNMANAGEDADJUSTMENT` (an edit was performed)
2. An entry exists in `ZINTERNALRESOURCE` with resource type 1 (a rendered file
   was produced)

This distinguishes visual edits from metadata-only adjustments that don't
produce a visible render. When `hasEdit` is false, `editedAt` and `editor` are
both null.

## The backup pipeline

`BackupPipeline.swift` orchestrates the full flow: filter → staging reuse →
adaptive export → upload (with network pause/resume) → manifest.

Internally `runBackup` decomposes into `filterPending`, `exportBatchWithFallback`,
the upload loop (`BackupUpload.swift`), and `finalizeBackup`. Each reads
top-to-bottom — no hidden state threaded through shared mutables.

### 1. Filter

`filterPending` combines four inputs:

1. Library assets from LadderKit.
2. Current manifest (already-backed-up UUIDs → skip).
3. Retry queue (previous run's failures → retry *first* on this run).
4. Unavailable store (permanently-unreachable assets → skip forever).

Optional filters narrow by type (`--type photo|video`) or count (`--limit N`).
Dry run stops here.

### 2. Staging reuse

`StagingReclaim` scans the staging directory for files from a prior aborted run
and matches them against pending UUIDs. Reclaimed files skip the PhotoKit
export round-trip — a meaningful speedup on resume.

### 3. Adaptive export

Pending assets are processed in batches (default 50). Each batch is passed to
LadderKit's `PhotoExporter`, which:

- Partitions the batch into **local** (cached originals) and **iCloud**
  (Optimize Storage) lanes via `LocalAvailabilityProviding`
  (`PhotosDatabaseLocalAvailability` reads `ZINTERNALRESOURCE.ZLOCALAVAILABILITY`).
- Runs the local lane at full `maxConcurrency`.
- Runs the iCloud lane at a limit polled from attic's `AIMDController`
  (observation-only; implements LadderKit's `AdaptiveConcurrencyControlling`).
  The controller maintains a sliding 20-outcome window: >30% transient failure
  rate → halve the limit; ≤5% → +1. Permanent failures (`-1728` asset
  unavailable, shared-album tombstones) are ignored as lane-health signals.
- Falls back to AppleScript via Photos.app when PhotoKit can't find an asset.
  `-1728` errors are classified `.permanentlyUnavailable` and recorded in the
  unavailable store.

See [Lanes and adaptive concurrency](lanes-and-adaptive-concurrency.md) for
the full rationale behind the split and the AIMD policy.

Each export result includes the file path, size, and SHA-256 hash (computed
inline during the streaming write — no second pass).

### 4. Upload

`BackupUpload.swift` runs bounded-concurrency uploads with retry. For each
exported file, attic:

1. Uploads the original to `originals/{year}/{month}/{uuid}.{ext}` via
   `URLSessionS3Client.putObject(key:fileURL:contentType:)`, streaming from
   disk (no memory load).
2. Builds and uploads metadata JSON to `metadata/assets/{uuid}.json` (see
   `docs/metadata.md`).
3. Updates the in-memory manifest.
4. Cleans up the staged file.

S3 keys are built from UUID and extension, both validated with regex
(`/^[A-Za-z0-9._-]+$/` and `/^[a-z0-9]+$/`) to prevent path traversal.
Extensions are resolved from the asset's UTI via a lookup table, falling back
to the filename extension.

**Network pause/resume**: on a network-down error, the upload loop drains the
current pass, queues the failed inputs, waits for `NetworkMonitoring` to
report recovery (with timeout), then restarts the pass. Capped by
`maxPauseRetries`. The manifest is saved before each pause so a long outage
doesn't lose progress.

**Retries**: S3 requests use exponential backoff on transient errors
(timeouts, `ECONNRESET`, etc.). Per-request timeouts scale with body size so
large video uploads don't trip a dead-connection check.

### 5. Manifest

The manifest is stored on S3 at `manifest.json` in the bucket root, mapping
UUID to `{ s3Key, checksum, backedUpAt }`. S3 is the single source of truth —
no local manifest. This enables cross-machine and cross-app (CLI ↔ future
menu bar app) continuity.

On backup start, the manifest is downloaded from S3. It's saved at **batch
boundaries** (and before network pauses) for crash resilience, and always at
the end of a run.

**Migration**: existing local manifests at `~/.attic/manifest.json` (from the
earlier Deno CLI) are uploaded to S3 on first run via
`loadManifestWithMigration()`.

The manifest can be reconstructed from S3 via `attic rebuild`, which reads
every `metadata/assets/*.json` file and validates UUID, S3 key, and checksum
format before accepting an entry.

### 6. Retry queue and unavailable store

Two auxiliary JSON files persist failure state across runs:

- **`retry-queue.json`** — transient failures. Each entry carries
  `classification`, `attempts`, `firstFailedAt`, `lastFailedAt`, `lastMessage`.
  Merge semantics preserve `firstFailedAt` and increment `attempts`, so the
  UI can surface "stuck for 3 days". Entries attempted-and-succeeded on a
  later run are removed; entries never attempted (e.g. when `--limit` cut
  the run short) survive with their full history.
- **`unavailable-assets.json`** — `.permanentlyUnavailable` assets
  (typically shared-album derivatives gone server-side). Never auto-cleared.
  Retrying is pointless; only user action (via a future command) clears.

## Verification

`VerifyPipeline.swift` checks backup integrity by issuing a HEAD request for
each S3 key in the manifest to confirm the object exists. Uses bounded
concurrency via TaskGroup (default 20 workers). Errors are capped at 1,000 to
prevent unbounded memory growth.

## Configuration

Attic reads its configuration from `~/.attic/config.json`. The config file
specifies the S3 endpoint, region, bucket, path-style preference, and Keychain
service names. It's created by `attic init` or manually. Config writes are
atomic (write-to-temp, then move) with `0o600` permissions.

`scan` works without config (it only reads the Photos library). All other
commands (`status`, `backup`, `verify`, `refresh-metadata`) require config and
S3 credentials since the manifest is stored on S3.

## Credentials

S3 credentials are stored in the macOS Keychain under configurable service names
(defaults: `attic-s3-access-key` and `attic-s3-secret-key`) with
`kSecAttrAccessibleWhenUnlocked` accessibility. They are read at runtime via the
Security framework — never stored in env vars, config files, or code.

## Interfaces and testability

All external dependencies are behind protocols:

| Protocol                          | Real implementation                      | Mock                                           |
| --------------------------------- | ---------------------------------------- | ---------------------------------------------- |
| `S3Providing`                     | `URLSessionS3Client` (SigV4 via aws-signer-v4; no AWS SDK) | `MockS3Provider` (in-memory actor, ships in AtticCore) |
| `ExportProviding`                 | `LadderKitExportProvider` (in AtticCLI)  | `MockExportProvider` / `TimeoutExportProvider` |
| `ManifestStoring`                 | `S3ManifestStore`                        | Uses `MockS3Provider`                          |
| `ConfigProviding`                 | `FileConfigProvider`                     | Direct struct construction in tests            |
| `KeychainProviding`               | `SecurityKeychain`                       | Direct struct construction in tests            |
| `NetworkMonitoring`               | `NWPathNetworkMonitor` (Network framework) | `MockNetworkMonitor`                         |
| `AdaptiveConcurrencyControlling` (LadderKit) | `AIMDController` (AtticCore)    | Any stub conforming to the protocol            |
| `LocalAvailabilityProviding` (LadderKit)     | `PhotosDatabaseLocalAvailability`       | Any stub conforming to the protocol            |
| `ThumbnailProviding`              | `ThumbnailService` (viewer thumbnails)   | —                                              |

Tests never hit external services, credentials, or the real Photos library.
AtticCore ships `MockS3Provider` as a public type so the menu bar app can
wire fake S3 for SwiftUI previews without duplicating test infrastructure.

## What attic doesn't do

- **Modify the Photos library** — read-only access, always
- **Download from iCloud directly** — LadderKit handles iCloud-only assets via
  AppleScript fallback through Photos.app
- **Delete from S3** — the backup is append-only; there is no prune or cleanup
  command
- **Back up thumbnails** — only original files and metadata
- **Back up adjustment plists** — Apple's edit recipes are not portable
- **Back up rendered edits** — detecting edits is implemented; exporting and
  uploading rendered versions is planned
- **Handle slo-mo or Live Photos specially** — these have unique resource types
  that need dedicated investigation
- **Run on non-macOS** — depends on PhotoKit, Keychain, and Photos.sqlite
