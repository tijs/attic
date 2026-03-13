# Attic

Deno/TypeScript CLI for backing up iCloud Photos to Scaleway S3. Part of the photo-cloud system (companion: [ladder](https://github.com/tijs/ladder)).

## Commands

```bash
deno task check       # Type check
deno task test        # Run tests (44 tests)
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

## Reference Docs

- [Architecture](docs/architecture.md) — pipeline, reader, ladder protocol, manifest, interfaces, design boundaries
- [Asset Metadata](docs/metadata.md) — per-asset JSON schema uploaded to S3

## Conventions

- Files should stay under 500 lines
- Use `AssetKind.PHOTO` / `AssetKind.VIDEO` constants, not magic numbers
- S3 keys and UUIDs are validated with regex before interpolation (path traversal prevention)
- `removeStagedFile()` constrains deletion to the staging directory
