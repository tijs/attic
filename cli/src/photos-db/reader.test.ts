import { assertEquals } from "@std/assert";
import { Database } from "@db/sqlite";
import { coreDataTimestampToDate, openPhotosDb } from "./reader.ts";
import { AssetKind, CloudLocalState } from "@attic/shared";

function createTestDb(): string {
  const path = Deno.makeTempFileSync({ suffix: ".sqlite" });
  const db = new Database(path);

  db.exec(`
    CREATE TABLE ZASSET (
      Z_PK INTEGER PRIMARY KEY,
      ZUUID TEXT,
      ZFILENAME TEXT,
      ZDIRECTORY TEXT,
      ZDATECREATED REAL,
      ZKIND INTEGER,
      ZUNIFORMTYPEIDENTIFIER TEXT,
      ZWIDTH INTEGER,
      ZHEIGHT INTEGER,
      ZLATITUDE REAL,
      ZLONGITUDE REAL,
      ZFAVORITE INTEGER,
      ZCLOUDLOCALSTATE INTEGER,
      ZTRASHEDSTATE INTEGER DEFAULT 0
    );

    CREATE TABLE ZADDITIONALASSETATTRIBUTES (
      Z_PK INTEGER PRIMARY KEY,
      ZASSET INTEGER,
      ZORIGINALFILESIZE INTEGER,
      ZORIGINALFILENAME TEXT,
      ZORIGINALSTABLEHASH TEXT
    );
  `);

  // 2024-01-15 12:00:00 UTC as CoreData timestamp
  // Unix: 1705320000 - CoreData epoch offset 978307200 = 727012800
  const coreDataTs = 727012800;

  db.exec(`
    INSERT INTO ZASSET (Z_PK, ZUUID, ZFILENAME, ZDIRECTORY, ZDATECREATED, ZKIND,
      ZUNIFORMTYPEIDENTIFIER, ZWIDTH, ZHEIGHT, ZLATITUDE, ZLONGITUDE, ZFAVORITE,
      ZCLOUDLOCALSTATE, ZTRASHEDSTATE)
    VALUES
      (1, 'uuid-photo-1', 'IMG_0001.HEIC', '/some/dir', ${coreDataTs}, ${AssetKind.PHOTO},
       'public.heic', 4032, 3024, 52.09, 4.34, 1, ${CloudLocalState.LOCAL}, 0),
      (2, 'uuid-video-1', 'IMG_0002.MOV', '/some/dir', ${
    coreDataTs + 3600
  }, ${AssetKind.VIDEO},
       'com.apple.quicktime-movie', 1920, 1080, NULL, NULL, 0, ${CloudLocalState.ICLOUD_ONLY}, 0),
      (3, 'uuid-trashed', 'IMG_0003.HEIC', '/some/dir', ${coreDataTs}, ${AssetKind.PHOTO},
       'public.heic', 4032, 3024, NULL, NULL, 0, ${CloudLocalState.LOCAL}, 1);

    INSERT INTO ZADDITIONALASSETATTRIBUTES (Z_PK, ZASSET, ZORIGINALFILESIZE, ZORIGINALFILENAME, ZORIGINALSTABLEHASH)
    VALUES
      (1, 1, 3158112, 'IMG_0001.HEIC', 'abc123'),
      (2, 2, 52428800, 'IMG_0002.MOV', 'def456'),
      (3, 3, 1000000, 'IMG_0003.HEIC', 'ghi789');
  `);

  db.close();
  return path;
}

Deno.test("coreDataTimestampToDate converts correctly", () => {
  // 2024-01-15 12:00:00 UTC = unix 1705320000 - 978307200 = 727012800
  const date = coreDataTimestampToDate(727012800);
  assertEquals(date?.toISOString(), "2024-01-15T12:00:00.000Z");
});

Deno.test("coreDataTimestampToDate returns null for null", () => {
  assertEquals(coreDataTimestampToDate(null), null);
});

Deno.test("readAssets returns non-trashed assets with correct fields", () => {
  const dbPath = createTestDb();
  try {
    const reader = openPhotosDb(dbPath);
    const assets = reader.readAssets();
    reader.close();

    assertEquals(assets.length, 2, "should exclude trashed asset");

    const photo = assets.find((a) => a.uuid === "uuid-photo-1")!;
    assertEquals(photo.filename, "IMG_0001.HEIC");
    assertEquals(photo.originalFilename, "IMG_0001.HEIC");
    assertEquals(photo.kind, AssetKind.PHOTO);
    assertEquals(photo.uniformTypeIdentifier, "public.heic");
    assertEquals(photo.width, 4032);
    assertEquals(photo.height, 3024);
    assertEquals(photo.latitude, 52.09);
    assertEquals(photo.longitude, 4.34);
    assertEquals(photo.favorite, true);
    assertEquals(photo.cloudLocalState, CloudLocalState.LOCAL);
    assertEquals(photo.originalFileSize, 3158112);
    assertEquals(photo.originalStableHash, "abc123");
    assertEquals(
      photo.dateCreated?.toISOString(),
      "2024-01-15T12:00:00.000Z",
    );

    const video = assets.find((a) => a.uuid === "uuid-video-1")!;
    assertEquals(video.kind, AssetKind.VIDEO);
    assertEquals(video.latitude, null);
    assertEquals(video.longitude, null);
    assertEquals(video.favorite, false);
    assertEquals(video.cloudLocalState, CloudLocalState.ICLOUD_ONLY);
    assertEquals(video.originalFileSize, 52428800);
  } finally {
    Deno.removeSync(dbPath);
  }
});
