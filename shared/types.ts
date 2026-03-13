/** Represents a single photo/video asset from the Photos library. */
export interface PhotoAsset {
  uuid: string;
  filename: string;
  originalFilename: string | null;
  directory: string | null;
  dateCreated: Date | null;
  kind: AssetKindValue;
  uniformTypeIdentifier: string | null;
  width: number;
  height: number;
  latitude: number | null;
  longitude: number | null;
  favorite: boolean;
  cloudLocalState: CloudLocalStateValue;
  originalFileSize: number | null;
  originalStableHash: string | null;
}

/** Cloud local state values from Photos.sqlite */
export const CloudLocalState = {
  /** Asset exists locally with original */
  LOCAL: 1,
  /** Asset is iCloud-only (thumbnail only) */
  ICLOUD_ONLY: 0,
} as const;

export type CloudLocalStateValue =
  typeof CloudLocalState[keyof typeof CloudLocalState];

/** Asset kind values */
export const AssetKind = {
  PHOTO: 0,
  VIDEO: 1,
} as const;

export type AssetKindValue = typeof AssetKind[keyof typeof AssetKind];
