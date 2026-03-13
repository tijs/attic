---
title: "feat: Back Up Rendered Edits Alongside Originals"
type: feat
status: active
date: 2026-03-13
brainstorm: docs/brainstorms/2026-03-13-edited-assets-backup-brainstorm.md
---

# Back Up Rendered Edits Alongside Originals

## Overview

Extend the backup pipeline to detect edited photos/videos and upload the
rendered (fullsize) version alongside the original to S3. Also detect edits on
already-backed-up assets and re-edits that produce newer renders. This makes the
backup self-contained and viewable without Apple Photos.

**Scope:** 1,312 edited assets out of 37,289 total (~3.5%), adding ~13.7 GB of
rendered files.

## Problem Statement

The backup currently stores only originals. Apple Photos edits are
non-destructive — the original is preserved, but the "finished" version requires
Apple Photos (or the adjustment plist) to re-render. If Photos.app is lost, the
user has the raw originals but not the edited versions they actually curated.

## Proposed Solution

Three-phase implementation that progresses from detection (metadata-only)
through ladder protocol changes to full rendered file backup.

## Design Decisions

| Decision                                      | Choice                                                     | Rationale                                           |
| --------------------------------------------- | ---------------------------------------------------------- | --------------------------------------------------- |
| S3 key layout                                 | `originals/{y}/{m}/{uuid}_edited.{ext}` sibling            | Easy to discover, clearly paired                    |
| Manifest schema                               | Extend existing entry with optional edit fields            | No schema break, simple comparison                  |
| Rendered file extension                       | From the rendered resource's UTI, not the original's       | A RAW `.orf` edited in Photos renders as HEIC       |
| Re-edit handling                              | Overwrite same `_edited` S3 key                            | S3 bucket versioning provides history if needed     |
| Edit revert                                   | Leave S3 file, clear manifest edit fields                  | Safe, cheap, no data loss                           |
| Slo-mo / Live Photos                          | Defer to follow-up                                         | 47 slo-mo + Live Photos have special resource types |
| Partial failure (original OK, rendered fails) | Back up original, retry rendered next run                  | Progressive backup, no data loss                    |
| Visual vs metadata-only edits                 | Check for rendered resource existence in ZINTERNALRESOURCE | Not all adjustments produce a visible render        |

## Implementation Phases

### Phase 1: Edit Detection and Metadata (TypeScript only)

Add edit awareness to the reader and metadata JSON without exporting rendered
files. This is independently useful and requires no ladder changes.

#### 1.1 Extend `PhotoAsset` type — `shared/types.ts`

Add three fields:

```typescript
hasEdit: boolean;
editedAt: Date | null;
editor: string | null;
```

Export nothing new from `shared/mod.ts` (these are primitive types on the
existing interface).

#### 1.2 Add edit enrichment query — `cli/src/photos-db/reader.ts`

New `buildEditMap()` following the existing enrichment pattern:

```sql
SELECT aa.ZASSET, ua.ZADJUSTMENTTIMESTAMP, ua.ZADJUSTMENTFORMATIDENTIFIER
FROM ZADDITIONALASSETATTRIBUTES aa
JOIN ZUNMANAGEDADJUSTMENT ua ON aa.ZUNMANAGEDADJUSTMENT = ua.Z_PK
WHERE aa.ZUNMANAGEDADJUSTMENT IS NOT NULL
```

Returns `Map<number, { editedAt: Date; editor: string }>` keyed by asset Z_PK.
Uses `safeQuery` for schema resilience. `ZADJUSTMENTTIMESTAMP` is CoreData
format — convert with existing `coreDataTimestampToDate()`.

Update `rowToAsset()` to merge edit data:

- `hasEdit`: `editMap.has(pk)`
- `editedAt`: from map or `null`
- `editor`: from `ZADJUSTMENTFORMATIDENTIFIER` or `null`

#### 1.3 Add rendered resource metadata query — `cli/src/photos-db/reader.ts`

Detect whether a rendered file actually exists (distinguishes visual edits from
metadata-only adjustments):

```sql
SELECT ir.ZASSET, ir.ZDATALENGTH, ir.ZCOMPACTUTI, ir.ZLOCALAVAILABILITY
FROM ZINTERNALRESOURCE ir
WHERE ir.ZRESOURCETYPE = 1
  AND ir.ZTRASHEDSTATE = 0
  AND ir.ZVERSION != 0
```

Returns `Map<number, { renderSize: number; renderLocallyAvailable: boolean }>`.
An asset `hasEdit = true` only if it appears in BOTH the adjustment map AND the
rendered resource map. This prevents trying to export rendered versions that
don't exist.

#### 1.4 Update metadata JSON — `cli/src/commands/backup.ts`

Add to `AssetMetadata`:

```typescript
hasEdit: boolean;
editedAt: string | null;
editor: string | null;
```

Simple pass-through from `PhotoAsset` in `buildMetadataJson()`.

#### 1.5 Update scan report — `cli/src/commands/scan.ts`

Add a line to `printScanReport()`:

```
Edited:        1,312  (rendered: 1,180 local, 132 iCloud-only)
```

#### 1.6 Tests — `cli/src/photos-db/reader.test.ts`

- Extend `createTestDb()` with `ZUNMANAGEDADJUSTMENT` and `ZINTERNALRESOURCE`
  tables
- Assert `hasEdit`, `editedAt`, `editor` on photo with edit data
- Assert `hasEdit: false` on video without edit data
- Schema resilience: missing adjustment tables return `hasEdit: false`

**Files modified:**

| File                               | Change                                                        | ~Lines |
| ---------------------------------- | ------------------------------------------------------------- | ------ |
| `shared/types.ts`                  | +3 fields on PhotoAsset                                       | +3     |
| `cli/src/photos-db/reader.ts`      | +buildEditMap, +buildRenderedResourceMap, merge in rowToAsset | +50    |
| `cli/src/commands/backup.ts`       | +3 fields in AssetMetadata + buildMetadataJson                | +6     |
| `cli/src/commands/scan.ts`         | Edit stats in report                                          | +10    |
| `cli/src/photos-db/reader.test.ts` | Edit enrichment fixtures + assertions                         | +40    |

**Verification:** `deno task check && deno task test && deno task scan` — scan
output shows edit counts.

---

### Phase 2: Ladder Protocol Extension (Swift)

Extend the ladder binary to export rendered versions via PhotoKit's
`PHAssetResource` API.

#### 2.1 Extend `ExportRequest` JSON schema — ladder

Current input format:

```json
{ "uuids": ["UUID/L0/001"], "stagingDir": "/path" }
```

New format — add optional `variant` field per UUID:

```json
{
  "requests": [
    { "id": "UUID/L0/001", "variant": "original" },
    { "id": "UUID/L0/001", "variant": "rendered" }
  ],
  "stagingDir": "/path"
}
```

If `variant` is omitted or `"original"`, use current behavior (`.photo` /
`.video` resource type). If `"rendered"`, use `.fullSizePhoto` /
`.fullSizeVideo`.

#### 2.2 Extend `ExportResult` JSON — ladder

Add `variant` to each result:

```json
{
  "uuid": "UUID",
  "variant": "rendered",
  "path": "/staging/UUID_rendered.heic",
  "size": 3158112,
  "sha256": "abc123"
}
```

The filename in `path` should reflect the actual rendered format (HEIC, JPEG,
MOV).

#### 2.3 PhotoKit resource selection — ladder Swift code

For rendered exports, use:

```swift
let resources = PHAssetResource.assetResources(for: asset)
let rendered = resources.first { $0.type == .fullSizePhoto }
    ?? resources.first { $0.type == .fullSizeVideo }
```

If no rendered resource exists, return an error result for that UUID+variant
(not a crash).

#### 2.4 Backward compatibility

If ladder receives the old `uuids` format (no `requests` field), fall back to
current behavior. This allows the TypeScript CLI to be deployed independently of
the ladder upgrade.

#### 2.5 Tests — ladder

- Export an edited photo: should return both original and rendered with correct
  variants
- Export an unedited photo with `variant: "rendered"`: should return an error
  (no fullsize resource)
- Old-format `uuids` input: should still work

**Verification:** Run ladder manually against a known edited asset, confirm both
variants export correctly.

---

### Phase 3: Full Rendered Backup Pipeline (TypeScript)

Wire the ladder protocol changes into the backup pipeline.

#### 3.1 S3 path helper — `shared/s3-paths.ts`

New exported function:

```typescript
export function editedKey(
  uuid: string,
  dateCreated: Date | null,
  ext: string,
): string;
```

Same structure as `originalKey()` but appends `_edited` before the extension.
Same UUID/extension regex validation. Tests follow existing patterns in
`s3-paths.test.ts`.

#### 3.2 Update Exporter interface — `cli/src/export/exporter.ts`

Extend `ExportedAsset` with variant:

```typescript
interface ExportedAsset {
  uuid: string;
  variant: "original" | "rendered";
  path: string;
  size: number;
  sha256: string;
}
```

Update `exportBatch()` signature:

```typescript
exportBatch(
  requests: Array<{ uuid: string; variant: "original" | "rendered" }>,
): Promise<ExportBatchResult>;
```

Update `createLadderExporter()` to send the new JSON format and parse variant
from results.

#### 3.3 Update mock exporter — `cli/src/export/exporter.mock.ts`

Mirror the interface changes. Mock data includes variant-tagged assets.

#### 3.4 Extend manifest — `cli/src/manifest/manifest.ts`

Add optional fields to `ManifestEntry`:

```typescript
interface ManifestEntry {
  uuid: string;
  s3Key: string;
  checksum: string;
  backedUpAt: string;
  editS3Key?: string;
  editChecksum?: string;
  editBackedUpAt?: string;
}
```

New helpers:

```typescript
function needsEditBackup(
  manifest: Manifest,
  uuid: string,
  editedAt: Date | null,
): boolean;
function markEditBackedUp(
  manifest: Manifest,
  uuid: string,
  checksum: string,
  s3Key: string,
): void;
```

`needsEditBackup()` returns `true` if:

- Asset has `hasEdit` and a rendered resource, AND
- No `editBackedUpAt` in manifest, OR `editedAt > editBackedUpAt`

#### 3.5 Update backup pipeline — `cli/src/commands/backup.ts`

The backup loop changes to handle three categories per batch:

1. **New assets** (not in manifest): export original + rendered (if edited),
   upload both
2. **Edit-pending assets** (in manifest, but `needsEditBackup()` is true):
   export rendered only, upload, update manifest
3. **Fully backed up** (in manifest, no pending edit): skip

The filtering step becomes:

```typescript
const newAssets = assets.filter((a) => !isBackedUp(manifest, a.uuid));
const editPending = assets.filter((a) =>
  isBackedUp(manifest, a.uuid) && needsEditBackup(manifest, a.uuid, a.editedAt)
);
```

For each new asset with `hasEdit`:

- Build export requests:
  `[{uuid, variant: "original"}, {uuid, variant: "rendered"}]`
- Upload original to `originalKey()`, rendered to `editedKey()`
- `markBackedUp()` + `markEditBackedUp()`

For each edit-pending asset:

- Build export request: `[{uuid, variant: "rendered"}]`
- Upload to `editedKey()`, update metadata JSON
- `markEditBackedUp()`

**Partial failure handling:** If original exports OK but rendered fails, upload
original and mark it in manifest. The edit will be retried on the next run
(detected by `needsEditBackup()`).

#### 3.6 Update verify command — `cli/src/commands/verify.ts`

When `entry.editS3Key` is present, also verify it with HEAD (quick mode) or
checksum (deep mode). Report edit verification separately:

```
Checked 100/100  OK: 98  Missing: 1  Corrupted: 0  Edits OK: 45  Edits Missing: 1
```

#### 3.7 Update status command — `cli/src/commands/status.ts`

Add edit backup progress:

```
Backed up:       35,000  (originals)
Edits backed up: 1,100 / 1,312
```

#### 3.8 Handle edit reverts

When `hasEdit` is `false` but manifest has `editS3Key`:

- Clear `editS3Key`, `editChecksum`, `editBackedUpAt` from manifest
- Re-upload metadata JSON (reflecting `hasEdit: false`)
- Leave the S3 file in place (orphaned, but cheap and safe)

#### 3.9 Tests

**backup.test.ts:**

- New asset with edit: both original + rendered uploaded, manifest has both keys
- Already-backed-up asset gains edit: only rendered uploaded, manifest updated
- Re-edited asset: rendered re-uploaded, manifest timestamp updated
- Edit reverted: manifest edit fields cleared, metadata re-uploaded
- Partial failure: original succeeds, rendered fails — original in manifest,
  edit retried

**manifest.test.ts:**

- `needsEditBackup()` returns true when no edit backed up
- `needsEditBackup()` returns true when editedAt > editBackedUpAt
- `needsEditBackup()` returns false when edit already current
- `markEditBackedUp()` sets edit fields

**s3-paths.test.ts:**

- `editedKey()` generates correct path
- `editedKey()` rejects unsafe UUID/extension

**Files modified:**

| File                                | Change                                                          | ~Lines |
| ----------------------------------- | --------------------------------------------------------------- | ------ |
| `shared/s3-paths.ts`                | +editedKey()                                                    | +15    |
| `shared/s3-paths.test.ts`           | editedKey tests                                                 | +20    |
| `cli/src/export/exporter.ts`        | Variant support in interface + ladder exporter                  | +30    |
| `cli/src/export/exporter.mock.ts`   | Mirror variant changes                                          | +15    |
| `cli/src/manifest/manifest.ts`      | +ManifestEntry edit fields, +needsEditBackup, +markEditBackedUp | +30    |
| `cli/src/manifest/manifest.test.ts` | Edit-aware manifest tests                                       | +30    |
| `cli/src/commands/backup.ts`        | Edit-aware pipeline + revert handling                           | +60    |
| `cli/src/commands/backup.test.ts`   | Edit backup scenarios                                           | +80    |
| `cli/src/commands/verify.ts`        | Verify editS3Key                                                | +15    |
| `cli/src/commands/status.ts`        | Edit backup stats                                               | +10    |

## Out of Scope (Future Work)

- **Slo-mo videos**: 47 assets with special resource types — needs dedicated
  investigation
- **Live Photos**: Paired still + video resources; edit may affect one or both
- **Adjustment plist backup**: The non-destructive recipe; low portability
  outside Apple Photos
- **Thumbnail/preview backup**: Other resource types (3, 14) not needed for a
  "viewable backup"
- **S3 cleanup of orphaned edit files**: Could add a `prune` command later

## Acceptance Criteria

### Phase 1

- [ ] `deno task scan` shows edit count and rendered resource availability
- [ ] Metadata JSON for edited assets includes `hasEdit`, `editedAt`, `editor`
- [ ] All existing tests pass; new tests cover edit enrichment + schema
      resilience

### Phase 2

- [ ] Ladder exports both original and rendered for an edited asset
- [ ] Ladder handles missing rendered resource gracefully (error, not crash)
- [ ] Old-format input still works (backward compat)

### Phase 3

- [ ] Edited assets get `_edited.{ext}` sibling uploaded to S3
- [ ] Already-backed-up assets with new edits get rendered version uploaded
- [ ] Re-edits detected and re-uploaded
- [ ] Reverted edits clear manifest edit fields
- [ ] Verify checks both original and edit S3 keys
- [ ] Status shows edit backup progress
- [ ] Partial failures (original OK, rendered fails) handled gracefully

## References

- Brainstorm: `docs/brainstorms/2026-03-13-edited-assets-backup-brainstorm.md`
- Current reader enrichment pattern: `cli/src/photos-db/reader.ts:130-201`
- Current S3 path helpers: `shared/s3-paths.ts`
- Current manifest schema: `cli/src/manifest/manifest.ts:5-15`
- Current backup pipeline: `cli/src/commands/backup.ts:61-243`
- Current exporter: `cli/src/export/exporter.ts`
- PhotoKit resource types: `PHAssetResourceType.fullSizePhoto` (type 3),
  `.fullSizeVideo` (type 5)
