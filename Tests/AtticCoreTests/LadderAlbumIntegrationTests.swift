@testable import AtticCore
import Foundation
import LadderKit
import SQLite3
import Testing

struct LadderAlbumIntegrationTests {
    @Test(arguments: [33, 34, 0, -1])
    func releasedLadderEnrichmentReachesAtticMetadata(schema: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("Photos.sqlite")
        var connection: OpaquePointer?
        try #require(sqlite3_open(path.path, &connection) == SQLITE_OK)
        let database = try #require(connection)
        let join = if schema > 0 {
            """
            CREATE TABLE Z_\(schema)ASSETS (Z_3ASSETS INTEGER, Z_\(schema)ALBUMS INTEGER);
            INSERT INTO Z_\(schema)ASSETS VALUES (1, 10), (1, 10);
            """
        } else if schema == -1 {
            "CREATE TABLE Z_34ASSETS (Z_3ASSETS INTEGER, Z_33ALBUMS INTEGER);"
        } else {
            ""
        }
        let sql = """
        CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZTRASHEDSTATE INTEGER,
            ZUNIFORMTYPEIDENTIFIER TEXT);
        INSERT INTO ZASSET VALUES (1, 'asset-1', 0, 'public.heic');
        CREATE TABLE ZGENERICALBUM (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZTITLE TEXT);
        INSERT INTO ZGENERICALBUM VALUES (10, 'album-1', 'Vacation');
        CREATE TABLE ZADDITIONALASSETATTRIBUTES (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER,
            ZORIGINALFILENAME TEXT);
        INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (100, 1, 'IMG_0001.HEIC');
        CREATE TABLE ZASSETDESCRIPTION (ZASSETATTRIBUTES INTEGER, ZLONGDESCRIPTION TEXT);
        INSERT INTO ZASSETDESCRIPTION VALUES (100, 'Synthetic description');
        \(join)
        """
        try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let before = try Data(contentsOf: path)

        var assets = [makeTestAsset(uuid: "asset-1")]
        PhotosDatabase.enrich(&assets, with: PhotosDatabase.readEnrichment(dbPath: path.path))
        let asset = try #require(assets.first).withResolvedCloudIdentity(.cloud("cloud/id+safe="))
        let metadata = buildMetadataJSON(
            asset: asset,
            s3Key: "originals/2024/01/cloud%2Fid%2Bsafe%3D.heic",
            checksum: "sha256:fixture",
            backedUpAt: "2024-01-01T00:00:00Z",
        )
        #expect(metadata.uuid == "cloud/id+safe=")
        #expect(metadata.identityKind == .cloud)
        #expect(metadata.legacyLocalIdentifier == "asset-1")
        #expect(metadata.originalFilename == "IMG_0001.HEIC")
        #expect(metadata.description == "Synthetic description")
        #expect(metadata.type == "public.heic")
        #expect(metadata.albums == (schema > 0 ? [AlbumRef(uuid: "album-1", title: "Vacation")] : []))
        let decoded = try JSONDecoder().decode(AssetMetadata.self, from: JSONEncoder().encode(metadata))
        #expect(decoded.uuid == metadata.uuid)
        #expect(decoded.albums == metadata.albums)
        #expect(try Data(contentsOf: path) == before)
    }
}
