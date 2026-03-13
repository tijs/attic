<p align="center">
  <img src="attic-logo.png" width="128" alt="attic logo">
</p>

# Attic

Back up your iCloud Photos library to S3-compatible storage.

Attic reads the Photos.sqlite database directly, exports originals via a
companion Swift tool called [ladder](https://github.com/tijs/ladder), and
uploads them to an S3-compatible bucket. A local manifest tracks what has
already been backed up so subsequent runs only upload new assets.

Works with any S3-compatible provider. EU-friendly options include
[Scaleway](https://www.scaleway.com/en/object-storage/),
[Hetzner](https://www.hetzner.com/storage/object-storage), and
[OVH](https://www.ovhcloud.com/en/public-cloud/object-storage/).

## Install

### Homebrew (recommended)

```bash
brew install tijs/tap/attic
```

### From source (requires Deno v2+)

```bash
git clone https://github.com/tijs/attic.git
cd attic
deno task install
```

This installs `attic` to `~/.deno/bin/`. Make sure that's on your PATH.

## Prerequisites

- The [ladder](https://github.com/tijs/ladder) binary. Ladder is a separate
  Swift tool that uses PhotoKit to export original photo/video files from the
  Photos library.
- An S3-compatible storage bucket and API credentials
- macOS (Photos.sqlite access and Keychain are macOS-only)

## Setup

Run the interactive setup:

```bash
attic init
```

This prompts for your S3 endpoint, region, bucket name, and credentials. Config
is saved to `~/.attic/config.json` and credentials are stored in the macOS
Keychain.

Build the ladder binary and add it to your PATH (see
[ladder](https://github.com/tijs/ladder) for details):

```bash
git clone https://github.com/tijs/ladder.git
cd ladder
swift build -c release
sudo cp .build/release/ladder /usr/local/bin/
```

Alternatively, pass `--ladder <path>` to the backup command or set the
`LADDER_PATH` environment variable.

## Commands

### init

Interactive setup — configure S3 connection and store credentials.

```bash
attic init
```

### scan

Scan the Photos library and print statistics (asset counts, sizes, types, local
vs iCloud-only).

```bash
attic scan
```

### status

Compare the Photos database against the local backup manifest to show how many
assets are backed up vs pending.

```bash
attic status
```

### backup

Export pending assets via ladder and upload originals + metadata JSON to S3.

```bash
attic backup
```

| Flag                  | Description                                              |
| --------------------- | -------------------------------------------------------- |
| `--dry-run`           | Show what would be uploaded without uploading            |
| `--limit N`           | Stop after N assets (useful for test runs)               |
| `--batch-size N`      | Assets per export batch (default: 50)                    |
| `--type photo\|video` | Only back up photos or videos                            |
| `--bucket NAME`       | Override bucket from config                              |
| `--ladder PATH`       | Path to the ladder binary (or set `LADDER_PATH` env var) |
| `--db PATH`           | Path to Photos.sqlite                                    |

### verify

Verify backup integrity by checking S3 objects against the manifest.

```bash
attic verify
```

| Flag                 | Description                                                |
| -------------------- | ---------------------------------------------------------- |
| `--deep`             | Download each object and re-verify SHA-256 checksum (slow) |
| `--rebuild-manifest` | Reconstruct the local manifest from S3 metadata files      |
| `--bucket NAME`      | Override bucket from config                                |

### refresh-metadata

Re-upload metadata JSON for already backed-up assets without re-uploading the
original files. Useful after adding new metadata fields or enrichments.

```bash
attic refresh-metadata
```

| Flag              | Description                      |
| ----------------- | -------------------------------- |
| `--dry-run`       | Show what would be uploaded      |
| `--concurrency N` | Concurrent uploads (default: 20) |
| `--bucket NAME`   | Override bucket from config      |
| `--db PATH`       | Path to Photos.sqlite            |

## Configuration

Attic stores its configuration at `~/.attic/config.json` (see
`config.example.json` for a template):

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

`scan` and `status` work without config (they only read Photos.sqlite). `backup`
and `verify` require config and will tell you to run `attic init` if it's
missing.

## Development

If you're working on attic itself, use `deno task` to run commands from source:

```bash
deno task check       # Type check
deno task test        # Run tests
deno task lint        # Lint
deno task fmt         # Format
deno task compile     # Build standalone binary
```

## Testing

```bash
deno task test
```

Tests use dependency injection with mock implementations for the S3 client and
exporter, so no external services or credentials are needed.

## Documentation

- [Architecture](docs/architecture.md) -- How attic works: the backup pipeline,
  Photos.sqlite reader, ladder protocol, manifest lifecycle, and design
  boundaries
- [Asset Metadata](docs/metadata.md) -- Schema reference for the per-asset JSON
  uploaded to S3

## Future Plans

- **Scheduled backups via launchd** -- A LaunchAgent plist to run backups daily
  on a dedicated Mac
- **Rendered edit backup** -- Detect and upload edited versions alongside
  originals (see `docs/plans/`)
