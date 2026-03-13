# Asset Metadata

Each backed-up asset gets a companion JSON file uploaded to S3 at `metadata/assets/{uuid}.json`. This file makes the backup browsable and searchable without access to Apple Photos or the original Photos.sqlite database.

## Example

```json
{
  "uuid": "8A3B1C2D-4E5F-6789-ABCD-EF0123456789",
  "originalFilename": "IMG_4231.HEIC",
  "dateCreated": "2024-07-14T16:23:41.000Z",
  "width": 4032,
  "height": 3024,
  "latitude": 52.0907,
  "longitude": 4.3386,
  "fileSize": 3158112,
  "type": "public.heic",
  "favorite": true,
  "title": "Sunset at the beach",
  "description": "A beautiful sunset over the ocean",
  "albums": [
    { "uuid": "album-uuid-1", "title": "Vacation 2024" },
    { "uuid": "album-uuid-2", "title": "Favorites" }
  ],
  "keywords": ["sunset", "ocean"],
  "people": [
    { "uuid": "person-uuid-1", "displayName": "Alice" }
  ],
  "hasEdit": true,
  "editedAt": "2024-07-14T18:45:00.000Z",
  "editor": "com.apple.photo",
  "s3Key": "originals/2024/07/8A3B1C2D-4E5F-6789-ABCD-EF0123456789.heic",
  "checksum": "sha256:a1b2c3d4e5f6...",
  "backedUpAt": "2026-03-13T10:30:00.000Z"
}
```

## Fields

### Asset identification

| Field | Type | Description |
|-------|------|-------------|
| `uuid` | string | Photos library UUID, unique per asset |
| `originalFilename` | string | Filename as imported (e.g. `IMG_4231.HEIC`) |

### Date and dimensions

| Field | Type | Description |
|-------|------|-------------|
| `dateCreated` | string \| null | ISO 8601 timestamp from Photos.sqlite (CoreData epoch converted) |
| `width` | number | Pixel width |
| `height` | number | Pixel height |

### Location

| Field | Type | Description |
|-------|------|-------------|
| `latitude` | number \| null | GPS latitude, null if no location data |
| `longitude` | number \| null | GPS longitude, null if no location data |

### File info

| Field | Type | Description |
|-------|------|-------------|
| `fileSize` | number \| null | Original file size in bytes |
| `type` | string \| null | Uniform Type Identifier (e.g. `public.heic`, `com.apple.quicktime-movie`) |
| `favorite` | boolean | Whether the asset is marked as a favorite in Photos |

### Enrichment

These fields come from auxiliary tables in Photos.sqlite via separate enrichment queries. All degrade gracefully — if the source table is missing (older macOS versions), the field returns its empty default.

| Field | Type | Default | Source table |
|-------|------|---------|--------------|
| `title` | string \| null | null | `ZADDITIONALASSETATTRIBUTES.ZTITLE` |
| `description` | string \| null | null | `ZASSETDESCRIPTION.ZLONGDESCRIPTION` |
| `albums` | AlbumRef[] | [] | `ZGENERICALBUM` via `Z_33ASSETS` join |
| `keywords` | string[] | [] | `ZKEYWORD` via `Z_1KEYWORDS` join |
| `people` | PersonRef[] | [] | `ZPERSON` via `ZDETECTEDFACE` join |

An `AlbumRef` contains `uuid` and `title`. A `PersonRef` contains `uuid` and `displayName`. People are deduplicated per asset (a person appears at most once even if detected in multiple face regions).

### Edit detection

| Field | Type | Description |
|-------|------|-------------|
| `hasEdit` | boolean | True only when both an adjustment record and a rendered resource exist |
| `editedAt` | string \| null | ISO 8601 timestamp of the edit, null when `hasEdit` is false |
| `editor` | string \| null | Bundle ID of the editing app (e.g. `com.apple.photo`, `com.pixelmator.photomator`), null when `hasEdit` is false |

`hasEdit` requires two conditions: an entry in `ZUNMANAGEDADJUSTMENT` (the edit happened) AND an entry in `ZINTERNALRESOURCE` with resource type 1 (a rendered file exists). Metadata-only adjustments that don't produce a visible render are excluded.

### Backup tracking

| Field | Type | Description |
|-------|------|-------------|
| `s3Key` | string | S3 object key where the original file is stored (e.g. `originals/2024/07/{uuid}.heic`) |
| `checksum` | string | SHA-256 hash of the uploaded file, prefixed with `sha256:` |
| `backedUpAt` | string | ISO 8601 timestamp of when this asset was uploaded |

## What's not included

- **Adjustment plists** — Apple's non-destructive edit recipes are not portable outside Photos
- **Thumbnail data** — Not useful for a full backup
- **iCloud sync state** — Only relevant at backup time, not for the archived copy
- **Face region coordinates** — Only person identity is stored, not bounding boxes
- **Slo-mo / Live Photo markers** — Deferred to a future phase
