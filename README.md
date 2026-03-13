<p align="center">
  <img src="attic-logo.png" width="128" alt="attic logo">
</p>

# Attic

Back up your iCloud Photos library to Scaleway Object Storage (S3-compatible).

Attic reads the Photos.sqlite database directly, exports originals via a companion Swift tool called [ladder](../ladder), and uploads them to a Scaleway S3 bucket. A local manifest tracks what has already been backed up so subsequent runs only upload new assets.

## Prerequisites

- [Deno](https://deno.land/) (v2+)
- The `ladder` binary, built from the sibling `../ladder` Swift project. Ladder uses PhotoKit to export original photo/video files from the Photos library.
- A Scaleway Object Storage bucket and API credentials
- macOS (Photos.sqlite access and Keychain are macOS-only)

## Setup

Store your Scaleway S3 credentials in the macOS Keychain:

```bash
security add-generic-password -s attic-s3-access-key -a attic -w "<your-access-key>"
security add-generic-password -s attic-s3-secret-key -a attic -w "<your-secret-key>"
```

Build the ladder binary:

```bash
cd ../ladder
swift build -c release
```

## Commands

All commands are run via `deno task`:

### scan

Scan the Photos library and print statistics (asset counts, sizes, types, local vs iCloud-only).

```bash
deno task scan
```

Optionally pass a custom database path:

```bash
deno task scan /path/to/Photos.sqlite
```

### status

Compare the Photos database against the local backup manifest to show how many assets are backed up vs pending.

```bash
deno task status
```

### backup

Export pending assets via ladder and upload originals + metadata JSON to S3.

```bash
deno task backup
```

Flags (append after `--`):

| Flag | Description |
|---|---|
| `--dry-run` | Show what would be uploaded without uploading |
| `--limit N` | Back up at most N assets |
| `--batch-size N` | Assets per ladder export batch (default: 50) |
| `--type photo\|video` | Only back up photos or videos |
| `--bucket NAME` | S3 bucket name (default: `photo-cloud-originals`) |
| `--ladder PATH` | Path to the ladder binary |
| `--db PATH` | Path to Photos.sqlite |

### verify

Verify backup integrity by checking S3 objects against the manifest.

```bash
deno task verify
```

| Flag | Description |
|---|---|
| `--deep` | Download each object and re-verify SHA-256 checksum (slow) |
| `--rebuild-manifest` | Reconstruct the local manifest from S3 metadata files |
| `--bucket NAME` | S3 bucket name (default: `photo-cloud-originals`) |

## S3 Bucket Structure

```
photo-cloud-originals/
  originals/
    2024/
      01/
        <uuid>.heic
        <uuid>.mov
      02/
        ...
  metadata/
    assets/
      <uuid>.json
```

- **originals/** -- Organized by year and month (UTC) from the asset's creation date. Each file is named by its Photos library UUID with the appropriate extension.
- **metadata/** -- One JSON file per asset containing original filename, dimensions, GPS coordinates, file size, UTI type, favorite status, S3 key, SHA-256 checksum, and backup timestamp.

## Local State

Attic stores its state in `~/.attic/`:

- `manifest.json` -- Tracks which assets have been backed up (UUID, S3 key, checksum, timestamp). The manifest is saved periodically during backup and can be rebuilt from S3 metadata via `verify --rebuild-manifest`.
- `staging/` -- Temporary directory where ladder exports files before upload. Files are cleaned up after each successful upload.

## Testing

```bash
deno task test
```

Tests use dependency injection with mock implementations for the S3 client and exporter, so no external services or credentials are needed.

## Project Structure

```
attic/
  deno.json              # Workspace config and task definitions
  shared/                # Shared types and utilities
    types.ts             # PhotoAsset, AssetKind, CloudLocalState
    s3-paths.ts          # S3 key generation (originalKey, metadataKey)
    s3-paths.test.ts
  cli/                   # CLI application
    mod.ts               # Entry point and argument parsing
    src/
      format.ts          # Byte formatting utility
      photos-db/
        reader.ts        # SQLite reader for Photos.sqlite
        reader.test.ts
      storage/
        s3-client.ts     # Scaleway S3 client (AWS SDK)
        s3-client.mock.ts
        s3-client.test.ts
      export/
        exporter.ts      # Ladder binary wrapper
        exporter.mock.ts
        exporter.test.ts
      manifest/
        manifest.ts      # Local backup manifest (JSON)
        manifest.test.ts
      commands/
        scan.ts          # Library scan report
        status.ts        # Backup status report
        backup.ts        # Backup pipeline
        backup.test.ts
        verify.ts        # Integrity verification
        verify.test.ts
        rebuild.ts       # Manifest reconstruction from S3
        rebuild.test.ts
```
