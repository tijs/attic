import { assertEquals } from "@std/assert";
import { Database } from "@db/sqlite";
import { coreDataTimestampToDate, openPhotosDb } from "./reader.ts";
import { AssetKind, CloudLocalState } from "@attic/shared";

function createTestDb(opts?: { withEnrichment?: boolean }): string {
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
      ZORIGINALSTABLEHASH TEXT,
      ZTITLE TEXT
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

    INSERT INTO ZADDITIONALASSETATTRIBUTES (Z_PK, ZASSET, ZORIGINALFILESIZE, ZORIGINALFILENAME, ZORIGINALSTABLEHASH, ZTITLE)
    VALUES
      (1, 1, 3158112, 'IMG_0001.HEIC', 'abc123', 'Sunset at the beach'),
      (2, 2, 52428800, 'IMG_0002.MOV', 'def456', NULL),
      (3, 3, 1000000, 'IMG_0003.HEIC', 'ghi789', NULL);
  `);

  if (opts?.withEnrichment !== false) {
    db.exec(`
      CREATE TABLE ZASSETDESCRIPTION (
        Z_PK INTEGER PRIMARY KEY,
        ZASSETATTRIBUTES INTEGER,
        ZLONGDESCRIPTION TEXT
      );

      CREATE TABLE ZGENERICALBUM (
        Z_PK INTEGER PRIMARY KEY,
        ZUUID TEXT,
        ZTITLE TEXT
      );

      CREATE TABLE Z_33ASSETS (
        Z_3ASSETS INTEGER,
        Z_33ALBUMS INTEGER
      );

      CREATE TABLE ZKEYWORD (
        Z_PK INTEGER PRIMARY KEY,
        ZTITLE TEXT
      );

      CREATE TABLE Z_1KEYWORDS (
        Z_1ASSETATTRIBUTES INTEGER,
        Z_52KEYWORDS INTEGER
      );

      CREATE TABLE ZPERSON (
        Z_PK INTEGER PRIMARY KEY,
        ZPERSONUUID TEXT,
        ZDISPLAYNAME TEXT
      );

      CREATE TABLE ZDETECTEDFACE (
        Z_PK INTEGER PRIMARY KEY,
        ZASSETFORFACE INTEGER,
        ZPERSONFORFACE INTEGER,
        ZHIDDEN INTEGER DEFAULT 0,
        ZASSETVISIBLE INTEGER DEFAULT 1
      );
    `);

    if (opts?.withEnrichment) {
      // Description for photo asset (aa.Z_PK = 1, aa.ZASSET = 1)
      db.exec(`
        INSERT INTO ZASSETDESCRIPTION (Z_PK, ZASSETATTRIBUTES, ZLONGDESCRIPTION)
        VALUES (1, 1, 'A beautiful sunset over the ocean');
      `);

      // Albums
      db.exec(`
        INSERT INTO ZGENERICALBUM (Z_PK, ZUUID, ZTITLE)
        VALUES (1, 'album-uuid-1', 'Vacation 2024'),
               (2, 'album-uuid-2', 'Favorites');

        INSERT INTO Z_33ASSETS (Z_3ASSETS, Z_33ALBUMS)
        VALUES (1, 1), (1, 2);
      `);

      // Keywords
      db.exec(`
        INSERT INTO ZKEYWORD (Z_PK, ZTITLE)
        VALUES (1, 'sunset'), (2, 'ocean');

        INSERT INTO Z_1KEYWORDS (Z_1ASSETATTRIBUTES, Z_52KEYWORDS)
        VALUES (1, 1), (1, 2);
      `);

      // People
      db.exec(`
        INSERT INTO ZPERSON (Z_PK, ZPERSONUUID, ZDISPLAYNAME)
        VALUES (1, 'person-uuid-1', 'Alice');

        INSERT INTO ZDETECTEDFACE (Z_PK, ZASSETFORFACE, ZPERSONFORFACE, ZHIDDEN, ZASSETVISIBLE)
        VALUES (1, 1, 1, 0, 1);
      `);
    }
  }

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
  const dbPath = createTestDb({ withEnrichment: true });
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

    // Enrichment fields
    assertEquals(photo.title, "Sunset at the beach");
    assertEquals(photo.description, "A beautiful sunset over the ocean");
    assertEquals(photo.albums.length, 2);
    assertEquals(photo.albums[0].title, "Vacation 2024");
    assertEquals(photo.albums[1].title, "Favorites");
    assertEquals(photo.keywords, ["sunset", "ocean"]);
    assertEquals(photo.people.length, 1);
    assertEquals(photo.people[0].displayName, "Alice");

    const video = assets.find((a) => a.uuid === "uuid-video-1")!;
    assertEquals(video.kind, AssetKind.VIDEO);
    assertEquals(video.latitude, null);
    assertEquals(video.longitude, null);
    assertEquals(video.favorite, false);
    assertEquals(video.cloudLocalState, CloudLocalState.ICLOUD_ONLY);
    assertEquals(video.originalFileSize, 52428800);

    // Video has no enrichment data
    assertEquals(video.title, null);
    assertEquals(video.description, null);
    assertEquals(video.albums, []);
    assertEquals(video.keywords, []);
    assertEquals(video.people, []);
  } finally {
    Deno.removeSync(dbPath);
  }
});

Deno.test("readAssets works without enrichment tables (schema resilience)", () => {
  const dbPath = createTestDb({ withEnrichment: false });
  try {
    const reader = openPhotosDb(dbPath);
    const assets = reader.readAssets();
    reader.close();

    assertEquals(assets.length, 2, "should return both non-trashed assets");

    const photo = assets.find((a) => a.uuid === "uuid-photo-1")!;
    assertEquals(photo.title, "Sunset at the beach");
    assertEquals(photo.description, null);
    assertEquals(photo.albums, []);
    assertEquals(photo.keywords, []);
    assertEquals(photo.people, []);
  } finally {
    Deno.removeSync(dbPath);
  }
});
