@testable import AtticCLI
@testable import AtticCore
import Foundation
import LadderKit
import SQLite3
import Testing

private struct RestoreRoundTripExporter: ExportProviding {
    let staging: URL
    func checkPermissions() async throws {}
    func exportBatch(uuids: [String]) async throws -> ExportResponse {
        let results = try uuids.map { uuid in
            let data = Data("fixture original \(uuid)".utf8)
            let file = staging.appendingPathComponent(uuid + ".heic")
            try data.write(to: file)
            return ExportResult(
                uuid: uuid,
                path: file.path,
                size: Int64(data.count),
                sha256: RestoreTestSupport.hash(data),
            )
        }
        return ExportResponse(results: results, errors: [])
    }
}

private final class RestoreJSONCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var values: [String] {
        lock.withLock { lines }
    }
}

struct RestoreRoundTripTests {
    @Test(arguments: [33, 34])
    func releasedLadderEnrichmentThroughBackupVerifyAndRecovery(schema: Int) async throws {
        let parent = try RestoreTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let assets = try enrichedAssets(in: parent, schema: schema)
        for filesystem in [false, true] {
            let sourceRoot = parent.appendingPathComponent("source-\(filesystem)")
            let target = parent.appendingPathComponent("recovered-\(filesystem)")
            let staging = parent.appendingPathComponent("staging-\(filesystem)")
            for directory in [sourceRoot, target, staging] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            let objects: any ObjectProviding = filesystem
                ? try FilesystemObjectStore(destination: FilesystemDestination.initialize(at: sourceRoot)) :
                MockS3Provider()
            let store = ObjectManifestStore(s3: objects, allowsLegacyLocalMigration: false)
            var manifest = Manifest(thumbnailsCleanupApplied: true)
            let lines = RestoreJSONCapture()
            let progress = BackupJSONProgressDelegate(output: { lines.append($0) })
            let backup = try await runBackup(
                assets: assets, manifest: &manifest, manifestStore: store,
                exporter: RestoreRoundTripExporter(staging: staging), s3: objects, progress: progress,
            )
            progress.finish(report: backup, dryRun: false)
            #expect(backup.uploaded == 2)
            let events = try lines.values
                .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            #expect(events.filter { $0["event"] as? String == "completed" }.count == 1)
            #expect((events.last?["counts"] as? [String: Any])?["uploaded"] as? Int == backup.uploaded)
            #expect((events.last?["bytes"] as? [String: Any])?["uploaded"] as? Int == backup.totalBytes)
            #expect(!lines.values.joined().contains("\u{1B}"))
            #expect(try await runVerify(manifest: manifest, s3: objects).ok == 2)
            let before = try await objects.getObject(key: manifestS3Key)
            let keysBefore = try await objects.listObjects(prefix: "").map(\.key).sorted()
            let filtered = try await planRestore(
                manifest: manifest, source: objects, sourceID: "roundtrip-\(filesystem)",
                filters: RestoreFilters(album: "album-1"),
            )
            #expect(filtered.items.count == 1)
            #expect(filtered.items.first?.metadata.first?.albums.first?.uuid == "album-1")
            let plan = try await planRestore(manifest: manifest, source: objects, sourceID: "roundtrip-\(filesystem)")
            let downloads = try #require(objects as? any ObjectDownloading)
            #expect(try await runRestore(plan: plan, source: downloads, destination: target).restored == 2)
            let directory = try SafeDirectory(url: target)
            for item in plan.items {
                let handle = try #require(try directory.reader(key: item.relativePath))
                defer { try? handle.close() }
                #expect(try SafeDirectory.digest(handle).checksum == item.checksum)
            }
            #expect(try await objects.getObject(key: manifestS3Key) == before)
            #expect(try await objects.listObjects(prefix: "").map(\.key).sorted() == keysBefore)
            #expect(try await runRestore(plan: plan, source: downloads, destination: target).skipped == 2)
            if filesystem {
                let nested = sourceRoot.appendingPathComponent("recovery")
                try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
                await #expect(throws: RestoreError.self) { try await runRestore(
                    plan: plan,
                    source: downloads,
                    destination: nested,
                ) }
                #expect(try FileManager.default.contentsOfDirectory(atPath: nested.path).isEmpty)
                #expect(try await objects.getObject(key: manifestS3Key) == before)
            }
        }
    }

    private func enrichedAssets(in parent: URL, schema: Int) throws -> [AssetInfo] {
        let path = parent.appendingPathComponent("Photos.sqlite")
        var connection: OpaquePointer?
        try #require(sqlite3_open(path.path, &connection) == SQLITE_OK)
        let database = try #require(connection)
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZTRASHEDSTATE INTEGER, ZUNIFORMTYPEIDENTIFIER TEXT);
        INSERT INTO ZASSET VALUES (1, 'A', 0, 'public.heic'), (2, 'B', 0, 'public.heic');
        CREATE TABLE ZGENERICALBUM (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZTITLE TEXT);
        INSERT INTO ZGENERICALBUM VALUES (10, 'album-1', 'Vacation');
        CREATE TABLE Z_\(schema)ASSETS (Z_3ASSETS INTEGER, Z_\(schema)ALBUMS INTEGER);
        INSERT INTO Z_\(schema)ASSETS VALUES (1, 10);
        CREATE TABLE ZADDITIONALASSETATTRIBUTES (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZORIGINALFILENAME TEXT);
        INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (100, 1, 'same.heic'), (200, 2, 'same.heic');
        """
        try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        var assets = [makeTestAsset(uuid: "A"), makeTestAsset(uuid: "B")]
        PhotosDatabase.enrich(&assets, with: PhotosDatabase.readEnrichment(dbPath: path.path))
        return assets.map { $0.withResolvedCloudIdentity(.cloud("cloud/id+\($0.uuid)=")) }
    }
}
