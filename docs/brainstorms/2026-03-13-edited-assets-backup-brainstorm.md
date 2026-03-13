# Back Up Rendered Edits Alongside Originals

**Date:** 2026-03-13 **Status:** Ready for planning

## What We're Building

Extend the backup pipeline to detect edited photos/videos and upload the
rendered (fullsize JPEG) version alongside the original. Also detect edits made
to already-backed-up assets and upload their rendered versions retroactively.

## Why This Approach

The backup should be self-contained and viewable without Apple Photos. Currently
only originals are backed up. Apple Photos edits are non-destructive (the
original is always preserved), but the "finished" version a user actually wants
to see requires either Apple Photos or the adjustment plist to re-render.
Backing up the rendered version makes the backup independently useful.

## Current State

| Metric                                             | Value           |
| -------------------------------------------------- | --------------- |
| Total assets                                       | 37,289          |
| Edited assets                                      | 1,312 (3.5%)    |
| Rendered versions (fullsize JPEG, resource type 1) | 1,672 resources |
| Locally available renders                          | 1,480           |
| Original size (edited subset)                      | ~6.2 GB         |
| Rendered size (edited subset)                      | ~13.7 GB        |

Edit sources: Apple Photos (1,181), slo-mo (47), Google Photos (42), Markup
(11), Adobe Lens (9), Snapseed (3).

## Key Decisions

1. **Back up rendered versions** (not just adjustment plists). The fullsize JPEG
   is what users actually see. Plists are Apple-internal and not portable.

2. **Sibling key with `_edited` suffix** in S3:
   ```
   originals/2024/01/{uuid}.heic          # original
   originals/2024/01/{uuid}_edited.jpg    # rendered edit
   metadata/assets/{uuid}.json            # includes edit metadata
   ```

3. **Same pass as originals**. When processing a batch, detect edits and upload
   both files together. No separate command needed.

4. **Re-scan already-backed-up assets for new edits**. Compare adjustment
   timestamps against the manifest's `backedUpAt` to detect photos edited after
   their initial backup.

## Data Sources in Photos.sqlite

### Edit detection

- `ZUNMANAGEDADJUSTMENT` joined via `ZADDITIONALASSETATTRIBUTES` tells us an
  asset has been edited
- `ZADJUSTMENTTIMESTAMP` tells us when the edit happened
- `ZADJUSTMENTFORMATIDENTIFIER` tells us which editor (com.apple.photo,
  com.adobe.lens, etc.)

### Rendered file location

- `ZINTERNALRESOURCE` with `ZRESOURCETYPE = 1` (fullsize JPEG) points to the
  rendered version
- `ZLOCALAVAILABILITY = 1` means the file is on disk
- `ZDATALENGTH` gives the file size
- The actual file lives in the Photos Library package, path derivable from
  `ZDATASTORECLASSID` + fingerprint

### Export via ladder

- The current exporter uses PhotoKit ID `{uuid}/L0/001` for originals
- Rendered versions may need a different resource variant or direct file copy
  from the library package

## Scope

### In scope

- Detect which assets have edits (via ZUNMANAGEDADJUSTMENT)
- Add edit metadata to PhotoAsset and the S3 metadata JSON (hasEdit, editedAt,
  editor)
- Export and upload rendered fullsize JPEG alongside original
- Re-scan manifest for assets edited after backup
- Track edit backup state in manifest (so renders are not re-uploaded)

### Out of scope

- Backing up adjustment plists (edit recipes)
- Handling slo-mo video rendering (complex, different pipeline)
- Re-rendering from adjustment data outside Apple Photos
- Backing up thumbnails or other resource types

## Resolved Questions

1. **Manifest schema**: Extend the existing manifest entry with optional
   `editS3Key`, `editChecksum`, `editBackedUpAt` fields. No separate entries, no
   schema break.

2. **Re-edit handling**: Always upload the latest render. Compare adjustment
   timestamp against `editBackedUpAt` to detect re-edits. The backup should
   reflect the current state of the edit.

## Open Questions

1. **How does ladder/PhotoKit export the rendered version?** The current
   `/L0/001` suffix gets the original. Need to investigate what identifier or
   API call retrieves the fullsize rendered JPEG. May need a ladder change.

2. **What about iCloud-only rendered versions?** 1,480 of 1,672 renders are
   local. The remaining ~200 may need to be downloaded first, same as
   iCloud-only originals. Is there an existing mechanism for this?
