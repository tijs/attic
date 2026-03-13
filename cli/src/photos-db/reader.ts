import { Database } from "@db/sqlite";
import type {
  AssetKindValue,
  CloudLocalStateValue,
  PhotoAsset,
} from "@attic/shared";

const DEFAULT_DB_PATH = `${
  Deno.env.get("HOME")
}/Pictures/Photos Library.photoslibrary/database/Photos.sqlite`;

const ASSETS_QUERY = `
  SELECT
    a.ZUUID,
    a.ZFILENAME,
    a.ZDIRECTORY,
    a.ZDATECREATED,
    a.ZKIND,
    a.ZUNIFORMTYPEIDENTIFIER,
    a.ZWIDTH,
    a.ZHEIGHT,
    a.ZLATITUDE,
    a.ZLONGITUDE,
    a.ZFAVORITE,
    a.ZCLOUDLOCALSTATE,
    aa.ZORIGINALFILESIZE,
    aa.ZORIGINALFILENAME,
    aa.ZORIGINALSTABLEHASH
  FROM ZASSET a
  JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK
  WHERE a.ZTRASHEDSTATE = 0
`;

/** CoreData epoch (2001-01-01) offset from Unix epoch in seconds. */
const CORE_DATA_EPOCH_OFFSET = 978307200;

/** Convert CoreData timestamp to JS Date. */
export function coreDataTimestampToDate(
  timestamp: number | null | undefined,
): Date | null {
  if (timestamp == null) return null;
  return new Date((timestamp + CORE_DATA_EPOCH_OFFSET) * 1000);
}

interface RawRow {
  ZUUID: string;
  ZFILENAME: string | null;
  ZDIRECTORY: string | null;
  ZDATECREATED: number | null;
  ZKIND: number;
  ZUNIFORMTYPEIDENTIFIER: string | null;
  ZWIDTH: number;
  ZHEIGHT: number;
  ZLATITUDE: number | null;
  ZLONGITUDE: number | null;
  ZFAVORITE: number;
  ZCLOUDLOCALSTATE: number;
  ZORIGINALFILESIZE: number | null;
  ZORIGINALFILENAME: string | null;
  ZORIGINALSTABLEHASH: string | null;
}

const REQUIRED_COLUMNS = [
  "ZUUID",
  "ZFILENAME",
  "ZKIND",
  "ZWIDTH",
  "ZHEIGHT",
  "ZCLOUDLOCALSTATE",
];

function assertValidRow(row: Record<string, unknown>): void {
  for (const key of REQUIRED_COLUMNS) {
    if (!(key in row)) {
      throw new Error(
        `Photos database schema mismatch: missing column '${key}'. ` +
          `This may indicate an unsupported macOS version.`,
      );
    }
  }
}

function rowToAsset(row: RawRow): PhotoAsset {
  return {
    uuid: row.ZUUID,
    filename: row.ZFILENAME ?? "",
    directory: row.ZDIRECTORY,
    dateCreated: coreDataTimestampToDate(row.ZDATECREATED),
    kind: row.ZKIND as AssetKindValue,
    uniformTypeIdentifier: row.ZUNIFORMTYPEIDENTIFIER,
    width: row.ZWIDTH,
    height: row.ZHEIGHT,
    latitude: row.ZLATITUDE,
    longitude: row.ZLONGITUDE,
    favorite: row.ZFAVORITE === 1,
    cloudLocalState: row.ZCLOUDLOCALSTATE as CloudLocalStateValue,
    originalFileSize: row.ZORIGINALFILESIZE,
    originalFilename: row.ZORIGINALFILENAME,
    originalStableHash: row.ZORIGINALSTABLEHASH,
  };
}

export interface PhotosDbReader {
  readAssets(): PhotoAsset[];
  close(): void;
}

export function openPhotosDb(
  dbPath: string = DEFAULT_DB_PATH,
): PhotosDbReader {
  const db = new Database(dbPath, { readonly: true });

  return {
    readAssets(): PhotoAsset[] {
      const rows = db.prepare(ASSETS_QUERY).all() as unknown as Record<
        string,
        unknown
      >[];
      if (rows.length > 0) {
        assertValidRow(rows[0]);
      }
      return (rows as unknown as RawRow[]).map(rowToAsset);
    },
    close() {
      db.close();
    },
  };
}
