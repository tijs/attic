@testable import AtticCore
import Foundation
import Testing

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
            contentType: "application/json",
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
            body: Data("not json".utf8),
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
            body: Data("not valid json".utf8),
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
            body: Data(metaJSON.utf8),
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
            body: Data(metaJSON.utf8),
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

    @Test func infersCloudIdentityKindFromLegacyMismatch() async throws {
        // Metadata JSON omits identityKind but carries a legacyLocalIdentifier
        // distinct from uuid — implies the canonical uuid is a cloud id.
        // Without inference, rebuild would re-stamp this as .local and the
        // post-rebuild manifest would never be re-detected as needing
        // migration.
        let s3 = MockS3Provider()
        let store = S3ManifestStore(s3: s3)
        let metaJSON = """
        {
            "uuid": "CLOUD-A",
            "s3Key": "originals/2024/01/CLOUD-A.heic",
            "checksum": "sha256:c",
            "backedUpAt": "2024-01-01T00:00:00Z",
            "originalFilename": "x.heic",
            "width": 1, "height": 1,
            "favorite": false, "hasEdit": false,
            "albums": [], "keywords": [], "people": [],
            "legacyLocalIdentifier": "OLD-LOCAL"
        }
        """
        try await s3.putObject(
            key: "metadata/assets/CLOUD-A.json",
            body: Data(metaJSON.utf8),
        )
        let (manifest, _) = try await runRebuildManifest(s3: s3, manifestStore: store)
        #expect(manifest.entries["CLOUD-A"]?.identityKind == .cloud)
        #expect(manifest.entries["CLOUD-A"]?.legacyLocalIdentifier == "OLD-LOCAL")
    }

    @Test func defaultsToLocalWhenNoLegacyOrKindHint() async throws {
        let s3 = MockS3Provider()
        let store = S3ManifestStore(s3: s3)
        let metaJSON = """
        {
            "uuid": "uuid-bare",
            "s3Key": "originals/2024/01/uuid-bare.heic",
            "checksum": "sha256:b",
            "backedUpAt": "2024-01-01T00:00:00Z",
            "originalFilename": "x.heic",
            "width": 1, "height": 1,
            "favorite": false, "hasEdit": false,
            "albums": [], "keywords": [], "people": []
        }
        """
        try await s3.putObject(
            key: "metadata/assets/uuid-bare.json",
            body: Data(metaJSON.utf8),
        )
        let (manifest, _) = try await runRebuildManifest(s3: s3, manifestStore: store)
        #expect(manifest.entries["uuid-bare"]?.identityKind == .local)
    }
}
