import Testing
import Foundation
@testable import AtticCore

@Suite("MockS3Provider")
struct MockS3ProviderTests {
    @Test func putAndGetRoundTrip() async throws {
        let s3 = MockS3Provider()
        let data = Data("hello".utf8)
        try await s3.putObject(key: "test.txt", body: data, contentType: "text/plain")
        let result = try await s3.getObject(key: "test.txt")
        #expect(result == data)
    }

    @Test func getThrowsOnMissing() async {
        let s3 = MockS3Provider()
        do {
            _ = try await s3.getObject(key: "missing")
            Issue.record("Expected error")
        } catch {
            #expect(String(describing: error).contains("notFound"))
        }
    }

    @Test func headReturnsNilOnMissing() async throws {
        let s3 = MockS3Provider()
        let meta = try await s3.headObject(key: "missing")
        #expect(meta == nil)
    }

    @Test func headReturnsMetaForExistingObject() async throws {
        let s3 = MockS3Provider()
        let data = Data("hello world".utf8)
        try await s3.putObject(key: "test.txt", body: data, contentType: "text/plain")
        let meta = try await s3.headObject(key: "test.txt")
        #expect(meta?.contentLength == 11)
        #expect(meta?.contentType == "text/plain")
    }

    @Test func listObjectsWithPrefix() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(key: "photos/a.jpg", body: Data("a".utf8))
        try await s3.putObject(key: "photos/b.jpg", body: Data("b".utf8))
        try await s3.putObject(key: "videos/c.mp4", body: Data("c".utf8))

        let photos = try await s3.listObjects(prefix: "photos/")
        #expect(photos.count == 2)
        #expect(photos.map(\.key).contains("photos/a.jpg"))

        let videos = try await s3.listObjects(prefix: "videos/")
        #expect(videos.count == 1)
    }

    @Test func tracksCallCounts() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(key: "a", body: Data())
        try await s3.putObject(key: "b", body: Data())
        _ = try await s3.getObject(key: "a")

        #expect(await s3.putCount == 2)
        #expect(await s3.getCount == 1)
    }
}

@Suite("S3ManifestStore")
struct S3ManifestStoreTests {
    @Test func loadReturnsEmptyWhenKeyMissing() async throws {
        let s3 = MockS3Provider()
        let store = S3ManifestStore(s3: s3)
        let manifest = try await store.load()
        #expect(manifest.entries.isEmpty)
    }

    @Test func saveAndLoadRoundTrip() async throws {
        let s3 = MockS3Provider()
        let store = S3ManifestStore(s3: s3)
        var manifest = Manifest()
        manifest.markBackedUp(
            uuid: "uuid-1",
            s3Key: "originals/2024/01/uuid-1.heic",
            checksum: "sha256:abc",
            backedUpAt: "2024-01-15T00:00:00Z"
        )
        try await store.save(manifest)

        let loaded = try await store.load()
        #expect(loaded.isBackedUp("uuid-1"))
        #expect(loaded.entries["uuid-1"]?.s3Key == "originals/2024/01/uuid-1.heic")
    }

    @Test func savesWithCorrectContentType() async throws {
        let s3 = MockS3Provider()
        let store = S3ManifestStore(s3: s3)
        try await store.save(Manifest())

        let obj = await s3.objects["manifest.json"]
        #expect(obj?.contentType == "application/json")
    }
}

@Suite("Manifest migration")
struct ManifestMigrationTests {
    @Test func usesS3ManifestWhenPresent() async throws {
        let s3 = MockS3Provider()
        let store = S3ManifestStore(s3: s3)
        var existing = Manifest()
        existing.markBackedUp(
            uuid: "s3-uuid",
            s3Key: "originals/2024/01/s3.heic",
            checksum: "sha256:s3",
            backedUpAt: "2024-01-15T00:00:00Z"
        )
        try await store.save(existing)

        let manifest = try await loadManifestWithMigration(
            s3Store: store,
            localDirectory: URL(fileURLWithPath: "/nonexistent")
        )
        #expect(manifest.isBackedUp("s3-uuid"))
    }

    @Test func migratesLocalManifestToS3() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a local manifest
        let localJSON = """
        {
          "entries": {
            "local-uuid": {
              "uuid": "local-uuid",
              "s3Key": "originals/2024/01/local.heic",
              "checksum": "sha256:local",
              "backedUpAt": "2024-01-15T00:00:00Z"
            }
          }
        }
        """
        try localJSON.write(
            to: dir.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        let s3 = MockS3Provider()
        let store = S3ManifestStore(s3: s3)

        let manifest = try await loadManifestWithMigration(
            s3Store: store,
            localDirectory: dir
        )
        #expect(manifest.isBackedUp("local-uuid"))

        // Verify it was uploaded to S3
        let s3Manifest = try await store.load()
        #expect(s3Manifest.isBackedUp("local-uuid"))
    }

    @Test func returnsEmptyWhenNeitherExists() async throws {
        let s3 = MockS3Provider()
        let store = S3ManifestStore(s3: s3)
        let manifest = try await loadManifestWithMigration(
            s3Store: store,
            localDirectory: URL(fileURLWithPath: "/nonexistent")
        )
        #expect(manifest.entries.isEmpty)
    }

    @Test func s3TakesPrecedenceOverLocal() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Local manifest has one entry
        let localJSON = """
        {
          "entries": {
            "local-uuid": {
              "uuid": "local-uuid",
              "s3Key": "originals/2024/01/local.heic",
              "checksum": "sha256:local",
              "backedUpAt": "2024-01-15T00:00:00Z"
            }
          }
        }
        """
        try localJSON.write(
            to: dir.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        // S3 has a different entry
        let s3 = MockS3Provider()
        let store = S3ManifestStore(s3: s3)
        var s3Manifest = Manifest()
        s3Manifest.markBackedUp(
            uuid: "s3-uuid",
            s3Key: "originals/2024/01/s3.heic",
            checksum: "sha256:s3",
            backedUpAt: "2024-01-15T00:00:00Z"
        )
        try await store.save(s3Manifest)

        // S3 should win — local is not consulted
        let manifest = try await loadManifestWithMigration(
            s3Store: store,
            localDirectory: dir
        )
        #expect(manifest.isBackedUp("s3-uuid"))
        #expect(!manifest.isBackedUp("local-uuid"))
    }
}
