@testable import AtticCore
import Foundation
import LadderKit
import Testing

/// Regression suite that exercises every code path that touches a uuid
/// using the actual `PHCloudIdentifier.stringValue` shape observed in
/// production:
///
///     <UUID>:<index>:<base64-ish>
///
/// The beta.8 release shipped with `S3Paths.uuidPattern` rejecting
/// colons, which only surfaced when the user ran `attic migrate` against
/// a real iCloud library. These tests pin down the supported shape so
/// future validator tweaks cannot reintroduce that class of bug — for
/// migration, normal backup pipeline, manifest read/write, metadata
/// JSON, retry queue, and rebuild.
enum CloudIDFixture {
    /// Real-world shape — mirrors the example from beta.8's bug report.
    static let realistic = "41C24A89-1280-4C14-BF5E-E93545843128:001:AaiU4soYcBEybZPj3zsS91dxDF42"
    static let secondary = "9B0F2C7D-1234-5ABC-9E0F-1234567890AB:002:Zk9Q1pBcDeFgHi0123456789ABCDEFGH"
}

@Suite("PHCloudIdentifier shape — S3 key paths")
struct CloudIdentifierS3PathTests {
    @Test func metadataKey() throws {
        let key = try S3Paths.metadataKey(uuid: CloudIDFixture.realistic)
        #expect(key == "metadata/assets/\(CloudIDFixture.realistic).json")
    }

    @Test func originalKey() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2024-06-01T00:00:00Z"))
        let key = try S3Paths.originalKey(
            uuid: CloudIDFixture.realistic,
            dateCreated: date,
            extension: "heic",
        )
        #expect(key == "originals/2024/06/\(CloudIDFixture.realistic).heic")
    }

    @Test func thumbnailKey() throws {
        let key = try S3Paths.thumbnailKey(uuid: CloudIDFixture.realistic)
        #expect(key == "thumbnails/\(CloudIDFixture.realistic).jpg")
    }

    @Test func uuidValidatorAccepts() {
        #expect(S3Paths.isValidUUID(CloudIDFixture.realistic))
        #expect(S3Paths.isValidUUID(CloudIDFixture.secondary))
    }

    @Test func s3KeyValidatorAccepts() {
        #expect(S3Paths.isValidS3Key("metadata/assets/\(CloudIDFixture.realistic).json"))
        #expect(S3Paths.isValidS3Key("originals/2024/06/\(CloudIDFixture.realistic).heic"))
    }
}

@Suite("PHCloudIdentifier shape — manifest")
struct CloudIdentifierManifestTests {
    @Test func entryEncodeDecodeRoundTrip() throws {
        let entry = ManifestEntry(
            uuid: CloudIDFixture.realistic,
            s3Key: "originals/2024/06/\(CloudIDFixture.realistic).heic",
            checksum: "sha256:abc",
            backedUpAt: "2024-06-01T00:00:00Z",
            legacyLocalIdentifier: "ABC-123",
            identityKind: .cloud,
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ManifestEntry.self, from: data)
        #expect(decoded.uuid == CloudIDFixture.realistic)
        #expect(decoded.identityKind == .cloud)
    }

    @Test func manifestKeyedByCloudID() throws {
        var manifest = Manifest()
        manifest.markBackedUp(
            uuid: CloudIDFixture.realistic,
            s3Key: "originals/2024/06/x.heic",
            checksum: "sha256:abc",
            backedUpAt: "2024-06-01T00:00:00Z",
            legacyLocalIdentifier: "ABC-123",
            identityKind: .cloud,
        )
        let data = try manifest.encoded()
        let parsed = try Manifest.parse(from: data)
        #expect(parsed.entries[CloudIDFixture.realistic]?.identityKind == .cloud)
        #expect(parsed.isBackedUp(CloudIDFixture.realistic))
    }
}

@Suite("PHCloudIdentifier shape — metadata JSON")
struct CloudIdentifierMetadataTests {
    @Test func assetMetadataEncodeDecodeRoundTrip() throws {
        let meta = AssetMetadata(
            uuid: CloudIDFixture.realistic,
            originalFilename: "IMG.HEIC",
            dateCreated: nil,
            width: 4032, height: 3024,
            latitude: nil, longitude: nil,
            fileSize: nil,
            type: nil,
            favorite: false,
            title: nil,
            description: nil,
            albums: [],
            keywords: [],
            people: [],
            hasEdit: false,
            editedAt: nil,
            editor: nil,
            s3Key: "originals/2024/06/x.heic",
            checksum: "sha256:abc",
            backedUpAt: "2024-06-01T00:00:00Z",
            legacyLocalIdentifier: "ABC-123",
            identityKind: .cloud,
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(AssetMetadata.self, from: data)
        #expect(decoded.uuid == CloudIDFixture.realistic)
        #expect(decoded.identityKind == .cloud)
    }
}

@Suite("PHCloudIdentifier shape — retry queue + unavailable store")
struct CloudIdentifierRetryStoreTests {
    @Test func retryEntryRoundTrip() throws {
        let entry = RetryEntry(
            uuid: CloudIDFixture.realistic,
            attempts: 1,
            firstFailedAt: "2024-06-01",
            lastFailedAt: "2024-06-01",
            legacyLocalIdentifier: "ABC-123",
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RetryEntry.self, from: data)
        #expect(decoded.uuid == CloudIDFixture.realistic)
        #expect(decoded.legacyLocalIdentifier == "ABC-123")
    }

    @Test func unavailableAssetRoundTrip() throws {
        let asset = UnavailableAsset(
            uuid: CloudIDFixture.realistic,
            filename: "x.mov",
            reason: "shared-album",
            firstFailedAt: "2024-06-01",
            lastAttemptedAt: "2024-06-01",
            attempts: 1,
            legacyLocalIdentifier: "ABC-123",
        )
        let data = try JSONEncoder().encode(asset)
        let decoded = try JSONDecoder().decode(UnavailableAsset.self, from: data)
        #expect(decoded.uuid == CloudIDFixture.realistic)
        #expect(decoded.legacyLocalIdentifier == "ABC-123")
    }
}

@Suite("PHCloudIdentifier shape — end-to-end migration")
struct CloudIdentifierMigrationE2ETests {
    private typealias Support = MigrationRunnerTestSupport

    @Test func migrationCompletesWithRealisticCloudID() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: Support.v1ManifestData(entries: [("ABC-123", "originals/2024/06/ABC-123.heic")]),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/ABC-123.json",
            body: Support.metadataJSON(uuid: "ABC-123", s3Key: "originals/2024/06/ABC-123.heic"),
        )

        let resolver = Support.MockResolver([
            "ABC-123/L0/001": .cloud(CloudIDFixture.realistic),
        ])
        let runner = Support.makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "ABC-123", fullLocalIdentifier: "ABC-123/L0/001")],
        )

        let report = try await runner.run()
        #expect(report.cloudMigrated == 1)
        #expect(report.metadataRewritten == 1)

        let manifest = try await S3ManifestStore(s3: s3).load()
        let entry = try #require(manifest.entries[CloudIDFixture.realistic])
        #expect(entry.identityKind == .cloud)
        #expect(entry.legacyLocalIdentifier == "ABC-123")

        // Metadata JSON now lives at the cloud-id-keyed path.
        let metaKey = "metadata/assets/\(CloudIDFixture.realistic).json"
        let metaExists = try await s3.headObject(key: metaKey) != nil
        #expect(metaExists)

        // Old metadata key removed.
        let oldExists = try await s3.headObject(key: "metadata/assets/ABC-123.json") != nil
        #expect(!oldExists)
    }

    @Test func collisionWithRealisticCloudIDsKeepsWinner() async throws {
        let s3 = MockS3Provider()
        var dict: [String: ManifestEntry] = [:]
        dict["ABC"] = ManifestEntry(
            uuid: "ABC",
            s3Key: "originals/2024/01/ABC.heic",
            checksum: "sha256:ABC",
            backedUpAt: "2024-01-01T00:00:00Z",
        )
        dict["DEF"] = ManifestEntry(
            uuid: "DEF",
            s3Key: "originals/2024/02/DEF.heic",
            checksum: "sha256:DEF",
            backedUpAt: "2024-06-01T00:00:00Z",
        )
        let v1 = Manifest(version: 1, entries: dict)
        try await s3.putObject(
            key: manifestS3Key,
            body: v1.encoded(),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/ABC.json",
            body: Support.metadataJSON(uuid: "ABC", s3Key: "originals/2024/01/ABC.heic"),
        )
        try await s3.putObject(
            key: "metadata/assets/DEF.json",
            body: Support.metadataJSON(uuid: "DEF", s3Key: "originals/2024/02/DEF.heic"),
        )

        let resolver = Support.MockResolver([
            "ABC/L0/001": .cloud(CloudIDFixture.realistic),
            "DEF/L0/001": .cloud(CloudIDFixture.realistic),
        ])
        let runner = Support.makeRunner(
            s3: s3,
            resolver: resolver,
            library: [
                (bareUUID: "ABC", fullLocalIdentifier: "ABC/L0/001"),
                (bareUUID: "DEF", fullLocalIdentifier: "DEF/L0/001"),
            ],
        )

        let report = try await runner.run()
        #expect(report.rekeyCollisions == ["ABC"])
        let manifest = try await S3ManifestStore(s3: s3).load()
        let entry = try #require(manifest.entries[CloudIDFixture.realistic])
        #expect(entry.legacyLocalIdentifier == "DEF")
    }
}
