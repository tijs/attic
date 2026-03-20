# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Deno/TypeScript CLI for backing up iCloud Photos to S3-compatible storage. Part
of the photo-cloud system (companion: [ladder](https://github.com/tijs/ladder)).

## Commands

```bash
deno task check       # Type check (cli/mod.ts)
deno task test        # Run all tests
deno task lint        # Lint
deno task fmt         # Format
deno task fmt:check   # Check formatting
```

Run a single test file:

```bash
deno test --allow-read --allow-write --allow-env --allow-ffi --allow-net cli/src/commands/backup.test.ts
```

Run a single test by name:

```bash
deno test --allow-read --allow-write --allow-env --allow-ffi --allow-net --filter "test name" cli/src/commands/backup.test.ts
```

## Workspace Structure

Deno workspace with two members:

- `shared/` — `@attic/shared` — `PhotoAsset` type, `AssetKind`/`CloudLocalState` constants, S3 path helpers
- `cli/` — `@attic/cli` — all commands, config, storage, manifest, export logic

Import shared code as `@attic/shared` (mapped in `cli/deno.json`).

Key dependencies: `@aws-sdk/client-s3`, `@cliffy/command` (CLI framework), `@db/sqlite` (Photos.sqlite reader), `@std/crypto` (SHA-256).

## Architecture

The backup pipeline: `Photos.sqlite → reader.ts → PhotoAsset[] → backup.ts → ladder export → S3 upload → manifest update`

- **reader.ts** (`cli/src/photos-db/`) — reads Photos.sqlite read-only. Main query joins `ZASSET` + `ZADDITIONALASSETATTRIBUTES`, then six enrichment queries (albums, keywords, people, descriptions, edits, rendered resources) each return a `Map` keyed by Z_PK. Uses `safeQuery()` for resilience across macOS versions.
- **backup.ts** (`cli/src/commands/`) — orchestrates filter → batch → export → upload → manifest. Batches of 50 assets sent to ladder subprocess via JSON stdin/stdout.
- **S3 key format** — originals: `originals/{year}/{month}/{uuid}.{ext}`, metadata: `metadata/assets/{uuid}.json`
- **Manifest** (`~/.attic/manifest.json`) — maps UUID → `{ s3Key, checksum, backedUpAt }`. Atomic writes (write .tmp then rename). Saved every 50 assets during backup.

All external dependencies are behind interfaces (`S3Provider`, `Exporter`, `ManifestStore`, `PhotosDbReader`) for testability.

## Testing Patterns

Tests use mock implementations — never external services or credentials:

- `createMockS3Provider()` — in-memory `Map<string, Uint8Array>`
- `createMockExporter()` — returns pre-configured assets from a `Map`
- `makeAsset()` helper in test files creates `PhotoAsset` with sensible defaults and partial overrides

## Reference Docs

- [Architecture](docs/architecture.md) — pipeline, reader, ladder protocol, manifest, interfaces
- [Asset Metadata](docs/metadata.md) — per-asset JSON schema uploaded to S3

## Conventions

- Files should stay under 500 lines
- Use `AssetKind.PHOTO` / `AssetKind.VIDEO` constants, not magic numbers
- S3 keys and UUIDs are validated with regex before interpolation (path traversal prevention)
- `removeStagedFile()` constrains deletion to the staging directory
