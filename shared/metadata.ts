import type { AlbumRef, PersonRef, PhotoAsset } from "./types.ts";

/** Per-asset metadata JSON uploaded to S3 at metadata/assets/{uuid}.json. */
export interface AssetMetadata {
  uuid: string;
  originalFilename: string;
  dateCreated: string | null;
  width: number;
  height: number;
  latitude: number | null;
  longitude: number | null;
  fileSize: number | null;
  type: string | null;
  favorite: boolean;
  title: string | null;
  description: string | null;
  albums: AlbumRef[];
  keywords: string[];
  people: PersonRef[];
  hasEdit: boolean;
  editedAt: string | null;
  editor: string | null;
  s3Key: string;
  checksum: string;
  backedUpAt: string;
}

/** Build a metadata JSON object for upload to S3. */
export function buildMetadataJson(
  asset: PhotoAsset,
  s3Key: string,
  checksum: string,
  backedUpAt: string,
): AssetMetadata {
  return {
    uuid: asset.uuid,
    originalFilename: asset.originalFilename ?? asset.filename,
    dateCreated: asset.dateCreated?.toISOString() ?? null,
    width: asset.width,
    height: asset.height,
    latitude: asset.latitude,
    longitude: asset.longitude,
    fileSize: asset.originalFileSize,
    type: asset.uniformTypeIdentifier,
    favorite: asset.favorite,
    title: asset.title,
    description: asset.description,
    albums: asset.albums,
    keywords: asset.keywords,
    people: asset.people,
    hasEdit: asset.hasEdit,
    editedAt: asset.editedAt?.toISOString() ?? null,
    editor: asset.editor,
    s3Key,
    checksum,
    backedUpAt,
  };
}
