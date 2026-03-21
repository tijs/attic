import Testing
import Foundation
@testable import AtticCore

@Suite("RebuildManifest")
struct RebuildManifestTests {
    @Test func rebuildsManifestFromMetadataFiles() async throws {
        let s3 = MockS3Provider()
        let store = S3ManifestStore(s3: s3)

        // Upload a metadata JSON file to S3
        let metaJSON = """
        {
            "uuid": "uuid-1",
            "s3Key": "originals/2024/01/uuid-1.heic",
            "checksum": "sha256:abc123",
            "backedUpAt": "2024-01-15T00:00:00Z",
            "originalFilename": "IMG_0001.HEIC",
            "width": 4032,
            "height": 3024,
            "favorite": false,
            "hasEdit": false,
            "albums": [],
            "keywords": [],
            "people": []
        }
        """
        try await s3.putObject(
            key: "metadata/assets/uuid-1.json",
            body: Data(metaJSON.utf8),
            contentType: "application/json"
        )

        let (manifest, report) = try await runRebuildManifest(s3: s3, manifestStore: store)

        #expect(report.recovered == 1)
        #expect(report.errors.isEmpty)
        #expect(manifest.isBackedUp("uuid-1"))
        #expect(manifest.entries["uuid-1"]?.s3Key == "originals/2024/01/uuid-1.heic")
        #expect(manifest.entries["uuid-1"]?.checksum == "sha256:abc123")
    }

    @Test func skipsNonJSONFiles() async throws {
        let s3 = MockS3Provider()
        let store = S3ManifestStore(s3: s3)

        try await s3.putObject(
            key: "metadata/assets/readme.txt",
            body: Data("not json".utf8)
        )

        let (manifest, report) = try await runRebuildManifest(s3: s3, manifestStore: store)

        #expect(report.skipped == 1)
        #expect(report.recovered == 0)
        #expect(manifest.entries.isEmpty)
    }

    @Test func handlesInvalidJSON() async throws {
        let s3 = MockS3Provider()
        let store = S3ManifestStore(s3: s3)

        try await s3.putObject(
            key: "metadata/assets/broken.json",
            body: Data("not valid json".utf8)
        )

        let (manifest, report) = try await runRebuildManifest(s3: s3, manifestStore: store)

        #expect(report.errors.count == 1)
        #expect(report.recovered == 0)
        #expect(manifest.entries.isEmpty)
    }

    @Test func rejectsInvalidUUIDs() async throws {
        let s3 = MockS3Provider()
        let store = S3ManifestStore(s3: s3)

        let metaJSON = """
        {
            "uuid": "../evil",
            "s3Key": "originals/2024/01/evil.heic",
            "checksum": "sha256:abc123"
        }
        """
        try await s3.putObject(
            key: "metadata/assets/evil.json",
            body: Data(metaJSON.utf8)
        )

        let (manifest, report) = try await runRebuildManifest(s3: s3, manifestStore: store)

        #expect(report.errors.count == 1)
        #expect(report.recovered == 0)
        #expect(manifest.entries.isEmpty)
    }

    @Test func savesRebuiltManifestToS3() async throws {
        let s3 = MockS3Provider()
        let store = S3ManifestStore(s3: s3)

        let metaJSON = """
        {
            "uuid": "uuid-1",
            "s3Key": "originals/2024/01/uuid-1.heic",
            "checksum": "sha256:abc123",
            "backedUpAt": "2024-01-15T00:00:00Z"
        }
        """
        try await s3.putObject(
            key: "metadata/assets/uuid-1.json",
            body: Data(metaJSON.utf8)
        )

        _ = try await runRebuildManifest(s3: s3, manifestStore: store)

        // Verify manifest was persisted
        let loaded = try await store.load()
        #expect(loaded.isBackedUp("uuid-1"))
    }

    @Test func emptyS3ReturnsEmptyManifest() async throws {
        let s3 = MockS3Provider()
        let store = S3ManifestStore(s3: s3)

        let (manifest, report) = try await runRebuildManifest(s3: s3, manifestStore: store)

        #expect(report.recovered == 0)
        #expect(manifest.entries.isEmpty)
    }
}
