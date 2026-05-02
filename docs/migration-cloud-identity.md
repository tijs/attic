# Migration: device-local → cloud-stable identity (v1 → v2)

`attic 1.0.0-beta.8` introduces a one-time migration that switches the
on-S3 manifest and per-asset metadata from `PHAsset.localIdentifier`
(per-Mac) to `PHCloudIdentifier` (stable across every Mac signed into
the same iCloud Photos library).

Run this once on the Mac that originally produced the backup (or any
Mac signed into the same iCloud account). After migration, every other
Mac in the same library can run `attic status`, `attic backup`, and
`attic verify` and recognize the existing backup correctly.

## What it does

| Surface | Change |
|---------|--------|
| `manifest.json` | Re-keyed by cloud identifier; gains `version: 2`, per-entry `legacyLocalIdentifier`, `identityKind`. |
| `metadata/assets/<uuid>.json` | Renamed to `metadata/assets/<cloud-id>.json`; `uuid` field updated, `legacyLocalIdentifier` and `identityKind` added. Old keys deleted. |
| `~/.attic/retry-queue.json` | Re-keyed in place (local file). |
| `~/.attic/unavailable-assets.json` | Re-keyed in place (local file). |
| Original photo objects (`originals/.../<uuid>.<ext>`) | **Not moved.** Manifest's `s3Key` is opaque; existing paths stay valid. |
| `manifest.v1.json` (new) | Backup of the pre-migration manifest, retained on S3 for recovery. |

## Running the migration

The migration runs automatically the first time you invoke any command
that needs a v2 manifest (`status`, `backup`, `verify`, `refresh-metadata`,
`viewer`). You can also run it explicitly:

```sh
attic migrate            # interactive, prompts for confirmation
attic migrate --yes      # non-interactive (CI / scripts)
attic migrate --dry-run  # show what would change without writing
attic migrate --repair   # clear leftover staging key from a prior partial run
```

The migration is **idempotent and resumable** — if interrupted, simply
re-run. Steps complete in a fixed order with the atomic manifest swap
last, so a partial run leaves the canonical manifest as v1 and the
next command sees "still needs migrating".

## Before you start

- **iCloud Photos must be enabled** on the machine running the migration.
- **PhotoKit access must be granted to attic** (System Settings → Privacy
  & Security → Photos → attic). On a Mac that has never run attic before,
  the first migration call triggers the macOS authorization prompt.
- **Do not run the migration on multiple Macs in parallel.** Run it once
  on whichever Mac you prefer; the resulting v2 manifest is recognized
  by every other Mac afterwards.

## What if some assets have no cloud counterpart?

Assets that exist locally but were never uploaded to iCloud Photos
(e.g. imports on a Mac with iCloud Photos disabled at the time) cannot
be re-keyed to a cloud identifier. The migration keeps these as
`identityKind: .local` with the original device-local UUID. They behave
exactly as they did under v1 — they just won't be recognized as
"already backed up" if you try to back up the same library from a
different Mac.

## Recovering from a bad migration

The pre-migration manifest is preserved at `manifest.v1.json` on S3.
If something goes wrong:

```sh
# Inspect the v1 backup
aws s3 cp s3://<bucket>/manifest.v1.json -

# Roll back manually (one-shot)
aws s3 cp s3://<bucket>/manifest.v1.json s3://<bucket>/manifest.json
```

You can also re-run with `--repair` to retry from a clean state:

```sh
attic migrate --repair --yes
```

## Downgrade warning

`1.0.0-beta.8` and later refuse to read v1 manifests in any command
except `migrate`. Older attic binaries (beta.7 and earlier) **cannot
correctly read a v2 manifest** and should not be run after migration.
If you need to roll back the binary, restore the v1 manifest from
`manifest.v1.json` first.

## Edge cases

- **`.multipleIdentifiersFound`** — PhotoKit reports multiple cloud IDs
  for one local ID (shared / merged library). The migration keeps
  these as `identityKind: .local` and surfaces them in the report;
  we do not silently pick a winner.
- **Asset deleted from the library since the manifest was written** —
  Stays as `identityKind: .local` with its original UUID. Surfaced in
  the "Unmapped" count so you can audit if needed.
- **Two old UUIDs that map to the same cloud ID** — Keeps the entry
  with the most recent `backedUpAt`; surfaces both old UUIDs in the
  report.

## Related

- [Architecture: identity model](architecture.md)
- [Asset metadata schema](metadata.md)
