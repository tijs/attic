# Architecture

Attic reads the macOS Photos library, exports original files via a companion Swift tool, and uploads them to S3 with rich metadata. A local manifest tracks progress so runs are incremental.

## System overview

```
Photos.sqlite ──→ reader.ts ──→ PhotoAsset[] ──→ backup pipeline
                   (read-only)                        │
                                                      ├─→ ladder (Swift subprocess)
                                                      │     exports originals to staging/
                                                      │
                                                      ├─→ S3 upload (original + metadata JSON)
                                                      │
                                                      └─→ manifest.json (local progress tracker)
```

Attic never modifies Photos.sqlite. The database is opened read-only.

## Reading the Photos library

`reader.ts` queries Photos.sqlite in two stages:

**Main query** — a single SELECT joining `ZASSET` and `ZADDITIONALASSETATTRIBUTES` returns core fields: UUID, filename, date, dimensions, GPS, file size, UTI, favorite status, cloud state. Trashed assets are excluded.

**Enrichment queries** — seven independent queries each build a `Map` keyed by asset primary key (Z_PK). During row mapping, each asset is enriched from these maps with a default of `null` or `[]` if no match exists.

| Query | Source tables | Returns |
|-------|--------------|---------|
| Descriptions | `ZASSETDESCRIPTION` → `ZADDITIONALASSETATTRIBUTES` | `Map<number, string>` |
| Albums | `ZGENERICALBUM` → `Z_33ASSETS` | `Map<number, AlbumRef[]>` |
| Keywords | `ZKEYWORD` → `Z_1KEYWORDS` → `ZADDITIONALASSETATTRIBUTES` | `Map<number, string[]>` |
| People | `ZPERSON` → `ZDETECTEDFACE` | `Map<number, PersonRef[]>` |
| Edits | `ZUNMANAGEDADJUSTMENT` → `ZADDITIONALASSETATTRIBUTES` | `Map<number, EditInfo>` |
| Rendered resources | `ZINTERNALRESOURCE` (resource type 1) | `Set<number>` |

All enrichment queries go through `safeQuery()`, which catches "no such table" errors silently and logs other failures. This makes the reader resilient across macOS versions where table schemas may differ.

People are deduplicated per asset — a person appears at most once even if detected in multiple face regions.

### Edit detection

An asset is considered edited (`hasEdit: true`) only when two conditions are met:

1. An entry exists in `ZUNMANAGEDADJUSTMENT` (an edit was performed)
2. An entry exists in `ZINTERNALRESOURCE` with resource type 1 (a rendered file was produced)

This distinguishes visual edits from metadata-only adjustments that don't produce a visible render. When `hasEdit` is false, `editedAt` and `editor` are both null.

## The backup pipeline

`backup.ts` orchestrates the full flow: filter → batch → export → upload → manifest.

### 1. Filter

Assets are filtered against the manifest to find pending work. Optional filters narrow by type (`--type photo|video`) or count (`--limit N`). Dry run mode stops here.

### 2. Batch and export

Pending assets are processed in batches (default 50). Each batch is sent to **ladder**, a companion Swift binary that uses PhotoKit to export original files. Communication is via JSON over stdin/stdout:

```
attic → stdin:  { "uuids": ["UUID/L0/001", ...], "stagingDir": "/path" }
ladder → stdout: { "results": [...], "errors": [...] }
```

Each result includes the file path, size, and SHA-256 hash. PhotoKit identifiers use the `UUID/L0/001` format; attic strips the suffix before further processing. Ladder output is validated at the trust boundary with `assertExportBatchResult()`.

### 3. Upload

For each exported file, attic:

1. Reads the staged file from disk
2. Uploads the original to `originals/{year}/{month}/{uuid}.{ext}`
3. Builds and uploads a metadata JSON to `metadata/assets/{uuid}.json` (see `docs/metadata.md`)
4. Updates the in-memory manifest
5. Cleans up the staged file

S3 keys are built from UUID and extension, both validated with regex (`/^[A-Za-z0-9._-]+$/` and `/^[a-z0-9]+$/`) to prevent path traversal. Extensions are resolved from the asset's UTI via a lookup table, falling back to the filename extension.

### 4. Manifest

The manifest is a JSON file at `~/.attic/manifest.json` mapping UUID to `{ s3Key, checksum, backedUpAt }`. It's saved periodically during backup (every 50 assets by default) and always at the end. Writes are atomic: write to `.tmp`, then rename.

The manifest can be reconstructed from S3 via `verify --rebuild-manifest`, which reads every `metadata/assets/*.json` file and validates UUID format, S3 key pattern, and checksum format before accepting an entry.

## Verification

`verify.ts` checks backup integrity in two modes:

- **Quick** (default) — HEAD each S3 key in the manifest, confirm it exists
- **Deep** — download each object, compute SHA-256, compare to the manifest checksum

Both modes use a bounded concurrency pool (default 50 workers). Errors are capped at 1,000 to prevent unbounded memory growth.

## Credentials

S3 credentials are stored in the macOS Keychain under service names `attic-s3-access-key` and `attic-s3-secret-key`. They are read at runtime via `security find-generic-password` — never stored in env vars, config files, or code.

## Interfaces and testability

All external dependencies are behind interfaces:

| Interface | Real implementation | Mock |
|-----------|-------------------|------|
| `S3Provider` | AWS SDK client for Scaleway | In-memory `Map<string, Uint8Array>` |
| `Exporter` | Ladder subprocess | Returns pre-configured assets from a `Map` |
| `ManifestStore` | File-based JSON with atomic writes | Same implementation, pointed at a temp dir |
| `PhotosDbReader` | SQLite reader for Photos.sqlite | In-memory SQLite with test fixtures |

Tests never hit external services, credentials, or the real Photos library.

## What attic doesn't do

- **Modify Photos.sqlite** — read-only access, always
- **Download from iCloud** — relies on Photos having local copies of originals
- **Delete from S3** — the backup is append-only; there is no prune or cleanup command
- **Back up thumbnails** — only original files and metadata
- **Back up adjustment plists** — Apple's edit recipes are not portable
- **Back up rendered edits** — detecting edits is implemented (Phase 1); exporting and uploading rendered versions is planned (Phase 2/3, see `docs/plans/2026-03-13-feat-backup-rendered-edits-plan.md`)
- **Handle slo-mo or Live Photos specially** — these have unique resource types that need dedicated investigation
- **Run on non-macOS** — depends on Photos.sqlite, Keychain, and PhotoKit via ladder
