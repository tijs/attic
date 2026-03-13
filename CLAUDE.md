# Attic

Deno/TypeScript CLI for backing up iCloud Photos to Scaleway S3. Part of the photo-cloud system (companion: [ladder](https://github.com/tijs/ladder)).

## Commands

```bash
deno task check       # Type check
deno task test        # Run tests (42 tests)
deno task lint        # Lint
deno task fmt         # Format
deno task fmt:check   # Check formatting
```

## Workspace Structure

```
shared/          # @attic/shared — PhotoAsset type, S3 path helpers
cli/             # @attic/cli — commands, storage, manifest, export
  src/commands/  # scan, status, backup, verify, rebuild
  src/storage/   # S3 client + Keychain credential loading
  src/manifest/  # Local JSON manifest with atomic writes
  src/export/    # Exporter interface + ladder subprocess integration
```

## Architecture

- **Interface-driven**: `S3Provider`, `ManifestStore`, `Exporter` — all injected for testability
- **Mocks for testing**: `createMockS3Provider()`, `createMockExporter()` — tests never hit real services
- **Runtime validation at trust boundaries**: Photos.sqlite schema, manifest JSON, ladder subprocess output, S3 metadata during rebuild
- **Atomic manifest writes**: temp file + rename pattern in `ManifestStore.save()`
- **Credentials**: macOS Keychain via `security find-generic-password` — never in env vars or config files
- **Streaming uploads**: `putObject` accepts `ReadableStream<Uint8Array>` to avoid loading large files into memory

## S3 Bucket Structure

```
originals/{year}/{month}/{uuid}.{ext}    # Original photo/video files
metadata/assets/{uuid}.json              # Per-asset metadata JSON
```

## Conventions

- Files should stay under 500 lines
- Use `AssetKind.PHOTO` / `AssetKind.VIDEO` constants, not magic numbers
- S3 keys and UUIDs are validated with regex before interpolation (path traversal prevention)
- `removeStagedFile()` constrains deletion to the staging directory
