# Attic

Deno/TypeScript CLI for backing up iCloud Photos to S3-compatible storage. Part
of the photo-cloud system (companion: [ladder](https://github.com/tijs/ladder)).

## Commands

```bash
deno task check       # Type check
deno task test        # Run tests (58 tests)
deno task lint        # Lint
deno task fmt         # Format
deno task fmt:check   # Check formatting
```

## Workspace Structure

```
shared/          # @attic/shared — PhotoAsset type, S3 path helpers
cli/             # @attic/cli — commands, config, storage, manifest, export
  src/commands/  # init, scan, status, backup, verify, rebuild, refresh-metadata
  src/config/    # Config file (load, validate, write)
  src/keychain/  # macOS Keychain credential load/store
  src/storage/   # Generic S3 client (provider interface + AWS SDK)
  src/manifest/  # Local JSON manifest with atomic writes
  src/export/    # Exporter interface + ladder subprocess integration
```

## Reference Docs

- [Architecture](docs/architecture.md) — pipeline, reader, ladder protocol,
  manifest, interfaces, design boundaries
- [Asset Metadata](docs/metadata.md) — per-asset JSON schema uploaded to S3

## Conventions

- Files should stay under 500 lines
- Use `AssetKind.PHOTO` / `AssetKind.VIDEO` constants, not magic numbers
- S3 keys and UUIDs are validated with regex before interpolation (path
  traversal prevention)
- `removeStagedFile()` constrains deletion to the staging directory
