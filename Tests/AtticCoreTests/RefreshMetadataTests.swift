@testable import AtticCore
import Foundation
import LadderKit
import Testing

struct RefreshMetadataTests {
    @Test func refreshesMetadataForBackedUpAssets() async throws {
        let s3 = MockS3Provider()
        var manifest = Manifest()
        manifest.markBackedUp(
            uuid: "uuid-1",
            s3Key: "originals/2024/01/uuid-1.heic",
            checksum: "sha256:abc",
            backedUpAt: "2024-01-15T00:00:00Z",
        )

        let assets = [makeTestAsset(uuid: "uuid-1")]

        let report = try await runRefreshMetadata(
            assets: assets, manifest: manifest, s3: s3,
        )

        #expect(report.updated == 1)
        #expect(report.failed == 0)

        // Verify metadata was uploaded
        let metaKey = "metadata/assets/uuid-1.json"
        let data = try await s3.getObject(key: metaKey)
        let meta = try JSONDecoder().decode(AssetMetadata.self, from: data)
        #expect(meta.uuid == "uuid-1")
        #expect(meta.s3Key == "originals/2024/01/uuid-1.heic")
    }

    @Test func skipsAssetsNotInManifest() async throws {
        let s3 = MockS3Provider()
        let manifest = Manifest()
        let assets = [makeTestAsset(uuid: "uuid-1")]

        let report = try await runRefreshMetadata(
            assets: assets, manifest: manifest, s3: s3,
        )

        #expect(report.updated == 0)
        let objects = try await s3.listObjects(prefix: "metadata/")
        #expect(objects.isEmpty)
    }

    @Test func dryRunSkipsUpload() async throws {
        let s3 = MockS3Provider()
        var manifest = Manifest()
        manifest.markBackedUp(
            uuid: "uuid-1",
            s3Key: "originals/2024/01/uuid-1.heic",
            checksum: "sha256:abc",
        )

        let assets = [makeTestAsset(uuid: "uuid-1")]
        let options = RefreshMetadataOptions(dryRun: true)

        let report = try await runRefreshMetadata(
            assets: assets, manifest: manifest, s3: s3, options: options,
        )

        #expect(report.skipped == 1)
        #expect(report.updated == 0)
        let objects = try await s3.listObjects(prefix: "metadata/")
        #expect(objects.isEmpty)
    }

    @Test func emptyAssetsReturnsEmptyReport() async throws {
        let s3 = MockS3Provider()
        let manifest = Manifest()

        let report = try await runRefreshMetadata(
            assets: [], manifest: manifest, s3: s3,
        )

        #expect(report.updated == 0)
        #expect(report.failed == 0)
    }
}
