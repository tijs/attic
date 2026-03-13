import { Database } from "@db/sqlite";
import type {
  AlbumRef,
  AssetKindValue,
  CloudLocalStateValue,
  PersonRef,
  PhotoAsset,
} from "@attic/shared";
import { AssetKind, CloudLocalState } from "@attic/shared";

const DEFAULT_DB_PATH = `${
  Deno.env.get("HOME")
}/Pictures/Photos Library.photoslibrary/database/Photos.sqlite`;

const ASSETS_QUERY = `
  SELECT
    a.Z_PK,
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
    aa.ZORIGINALSTABLEHASH,
    aa.ZTITLE
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
  Z_PK: number;
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
  ZTITLE: string | null;
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

const VALID_ASSET_KINDS = new Set<number>(Object.values(AssetKind));
const VALID_CLOUD_STATES = new Set<number>(Object.values(CloudLocalState));

function assertAssetKind(value: number): AssetKindValue {
  if (!VALID_ASSET_KINDS.has(value)) {
    throw new Error(`Unknown asset kind: ${value}`);
  }
  return value as AssetKindValue;
}

function assertCloudLocalState(value: number): CloudLocalStateValue {
  if (!VALID_CLOUD_STATES.has(value)) {
    throw new Error(`Unknown cloud local state: ${value}`);
  }
  return value as CloudLocalStateValue;
}

interface EnrichmentMaps {
  descriptions: Map<number, string>;
  albums: Map<number, AlbumRef[]>;
  keywords: Map<number, string[]>;
  people: Map<number, PersonRef[]>;
}

function rowToAsset(row: RawRow, enrichment: EnrichmentMaps): PhotoAsset {
  const pk = row.Z_PK;
  return {
    uuid: row.ZUUID,
    filename: row.ZFILENAME ?? "",
    directory: row.ZDIRECTORY,
    dateCreated: coreDataTimestampToDate(row.ZDATECREATED),
    kind: assertAssetKind(row.ZKIND),
    uniformTypeIdentifier: row.ZUNIFORMTYPEIDENTIFIER,
    width: row.ZWIDTH,
    height: row.ZHEIGHT,
    latitude: row.ZLATITUDE,
    longitude: row.ZLONGITUDE,
    favorite: row.ZFAVORITE === 1,
    cloudLocalState: assertCloudLocalState(row.ZCLOUDLOCALSTATE),
    originalFileSize: row.ZORIGINALFILESIZE,
    originalFilename: row.ZORIGINALFILENAME,
    originalStableHash: row.ZORIGINALSTABLEHASH,
    title: row.ZTITLE ?? null,
    description: enrichment.descriptions.get(pk) ?? null,
    albums: enrichment.albums.get(pk) ?? [],
    keywords: enrichment.keywords.get(pk) ?? [],
    people: enrichment.people.get(pk) ?? [],
  };
}

function safeQuery<T>(db: Database, sql: string, label: string): T[] {
  try {
    return db.prepare(sql).all() as unknown as T[];
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    if (!msg.includes("no such table")) {
      console.error(`Enrichment query failed (${label}): ${msg}`);
    }
    return [];
  }
}

function buildDescriptionMap(db: Database): Map<number, string> {
  const rows = safeQuery<{ ZASSET: number; ZLONGDESCRIPTION: string }>(
    db,
    `SELECT aa.ZASSET, d.ZLONGDESCRIPTION
     FROM ZASSETDESCRIPTION d
     JOIN ZADDITIONALASSETATTRIBUTES aa ON d.ZASSETATTRIBUTES = aa.Z_PK
     WHERE d.ZLONGDESCRIPTION IS NOT NULL AND d.ZLONGDESCRIPTION != ''`,
    "descriptions",
  );
  const map = new Map<number, string>();
  for (const r of rows) map.set(r.ZASSET, r.ZLONGDESCRIPTION);
  return map;
}

function buildAlbumMap(db: Database): Map<number, AlbumRef[]> {
  const rows = safeQuery<
    { Z_3ASSETS: number; ZUUID: string; ZTITLE: string }
  >(
    db,
    `SELECT ja.Z_3ASSETS, g.ZUUID, g.ZTITLE
     FROM Z_33ASSETS ja
     JOIN ZGENERICALBUM g ON ja.Z_33ALBUMS = g.Z_PK
     WHERE g.ZTITLE IS NOT NULL`,
    "albums",
  );
  const map = new Map<number, AlbumRef[]>();
  for (const r of rows) {
    const list = map.get(r.Z_3ASSETS) ?? [];
    list.push({ uuid: r.ZUUID, title: r.ZTITLE });
    map.set(r.Z_3ASSETS, list);
  }
  return map;
}

function buildKeywordMap(db: Database): Map<number, string[]> {
  const rows = safeQuery<{ ZASSET: number; ZTITLE: string }>(
    db,
    `SELECT aa.ZASSET, k.ZTITLE
     FROM Z_1KEYWORDS jk
     JOIN ZKEYWORD k ON jk.Z_52KEYWORDS = k.Z_PK
     JOIN ZADDITIONALASSETATTRIBUTES aa ON jk.Z_1ASSETATTRIBUTES = aa.Z_PK
     WHERE k.ZTITLE IS NOT NULL`,
    "keywords",
  );
  const map = new Map<number, string[]>();
  for (const r of rows) {
    const list = map.get(r.ZASSET) ?? [];
    list.push(r.ZTITLE);
    map.set(r.ZASSET, list);
  }
  return map;
}

function buildPeopleMap(db: Database): Map<number, PersonRef[]> {
  const rows = safeQuery<
    { ZASSETFORFACE: number; ZPERSONUUID: string; ZDISPLAYNAME: string }
  >(
    db,
    `SELECT df.ZASSETFORFACE, p.ZPERSONUUID, p.ZDISPLAYNAME
     FROM ZDETECTEDFACE df
     JOIN ZPERSON p ON df.ZPERSONFORFACE = p.Z_PK
     WHERE p.ZDISPLAYNAME IS NOT NULL AND p.ZDISPLAYNAME != ''
       AND df.ZHIDDEN = 0 AND df.ZASSETVISIBLE = 1`,
    "people",
  );
  const map = new Map<number, PersonRef[]>();
  const seen = new Map<number, Set<string>>();
  for (const r of rows) {
    const assetSeen = seen.get(r.ZASSETFORFACE) ?? new Set();
    if (!assetSeen.has(r.ZPERSONUUID)) {
      assetSeen.add(r.ZPERSONUUID);
      seen.set(r.ZASSETFORFACE, assetSeen);
      const list = map.get(r.ZASSETFORFACE) ?? [];
      list.push({ uuid: r.ZPERSONUUID, displayName: r.ZDISPLAYNAME });
      map.set(r.ZASSETFORFACE, list);
    }
  }
  return map;
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

      const enrichment: EnrichmentMaps = {
        descriptions: buildDescriptionMap(db),
        albums: buildAlbumMap(db),
        keywords: buildKeywordMap(db),
        people: buildPeopleMap(db),
      };

      return (rows as unknown as RawRow[]).map((row) =>
        rowToAsset(row, enrichment)
      );
    },
    close() {
      db.close();
    },
  };
}
