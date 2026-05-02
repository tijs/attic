@testable import AtticCore
import Foundation
import Testing

struct ManifestTests {
    @Test func emptyManifest() {
        let manifest = Manifest()
        #expect(manifest.entries.isEmpty)
        #expect(!manifest.isBackedUp("any-uuid"))
    }

    @Test func markBackedUp() throws {
        var manifest = Manifest()
        manifest.markBackedUp(
            uuid: "test-uuid",
            s3Key: "originals/2024/01/test-uuid.heic",
            checksum: "sha256:abc123",
            size: 1024,
            backedUpAt: "2024-01-15T12:00:00Z",
        )

        #expect(manifest.isBackedUp("test-uuid"))
        #expect(!manifest.isBackedUp("other-uuid"))

        let entry = try #require(manifest.entries["test-uuid"])
        #expect(entry.uuid == "test-uuid")
        #expect(entry.s3Key == "originals/2024/01/test-uuid.heic")
        #expect(entry.checksum == "sha256:abc123")
        #expect(entry.size == 1024)
        #expect(entry.backedUpAt == "2024-01-15T12:00:00Z")
    }

    @Test func markBackedUpDefaultsTimestamp() throws {
        var manifest = Manifest()
        manifest.markBackedUp(
            uuid: "test-uuid",
            s3Key: "originals/2024/01/test-uuid.heic",
            checksum: "sha256:abc123",
        )

        let entry = try #require(manifest.entries["test-uuid"])
        #expect(!entry.backedUpAt.isEmpty)
    }

    @Test func newManifestIsV2() {
        let manifest = Manifest()
        #expect(manifest.version == 2)
        #expect(!manifest.isV1)
    }

    @Test func decodesLegacyManifestWithoutVersionAsV1() throws {
        let json = """
        {
          "entries": {
            "ABC": {
              "uuid": "ABC",
              "s3Key": "originals/2024/01/ABC.heic",
              "checksum": "sha256:aaa",
              "backedUpAt": "2024-01-01T00:00:00Z"
            }
          }
        }
        """
        let manifest = try Manifest.parse(from: Data(json.utf8))
        #expect(manifest.version == 1)
        #expect(manifest.isV1)
        let entry = try #require(manifest.entries["ABC"])
        #expect(entry.identityKind == .local)
        #expect(entry.legacyLocalIdentifier == nil)
    }

    @Test func markBackedUpRecordsCloudIdentity() throws {
        var manifest = Manifest()
        manifest.markBackedUp(
            uuid: "CLOUD-XYZ",
            s3Key: "originals/2024/01/old-local.heic",
            checksum: "sha256:abc",
            size: 1024,
            backedUpAt: "2024-01-01T00:00:00Z",
            legacyLocalIdentifier: "old-local",
            identityKind: .cloud,
        )
        let entry = try #require(manifest.entries["CLOUD-XYZ"])
        #expect(entry.identityKind == .cloud)
        #expect(entry.legacyLocalIdentifier == "old-local")
    }

    @Test func encodesV2ManifestWithVersionField() throws {
        var manifest = Manifest()
        manifest.markBackedUp(
            uuid: "u1",
            s3Key: "k1",
            checksum: "sha256:c",
            backedUpAt: "2024-01-01T00:00:00Z",
            identityKind: .cloud,
        )
        let data = try manifest.encoded()
        let parsed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(parsed["version"] as? Int == 2)
        let entries = try #require(parsed["entries"] as? [String: Any])
        let entry = try #require(entries["u1"] as? [String: Any])
        #expect(entry["identityKind"] as? String == "cloud")
    }

    @Test func v2RoundTripPreservesIdentityFields() throws {
        var original = Manifest()
        original.markBackedUp(
            uuid: "CLOUD-A",
            s3Key: "originals/2024/01/legacy.heic",
            checksum: "sha256:a",
            size: 100,
            backedUpAt: "2024-01-01T00:00:00Z",
            legacyLocalIdentifier: "legacy",
            identityKind: .cloud,
        )
        original.markBackedUp(
            uuid: "LOCAL-B",
            s3Key: "originals/2024/01/LOCAL-B.heic",
            checksum: "sha256:b",
            backedUpAt: "2024-01-02T00:00:00Z",
            legacyLocalIdentifier: "LOCAL-B",
            identityKind: .local,
        )
        let data = try original.encoded()
        let parsed = try Manifest.parse(from: data)
        #expect(parsed.version == 2)
        #expect(parsed.entries["CLOUD-A"]?.identityKind == .cloud)
        #expect(parsed.entries["CLOUD-A"]?.legacyLocalIdentifier == "legacy")
        #expect(parsed.entries["LOCAL-B"]?.identityKind == .local)
        #expect(parsed.entries["LOCAL-B"]?.legacyLocalIdentifier == "LOCAL-B")
    }

    @Test func encodeAndParseRoundTrip() throws {
        var manifest = Manifest()
        manifest.markBackedUp(
            uuid: "uuid-1",
            s3Key: "originals/2024/01/uuid-1.heic",
            checksum: "sha256:aaa",
            size: 500,
            backedUpAt: "2024-01-01T00:00:00Z",
        )
        manifest.markBackedUp(
            uuid: "uuid-2",
            s3Key: "originals/2024/02/uuid-2.jpg",
            checksum: "sha256:bbb",
            backedUpAt: "2024-02-01T00:00:00Z",
        )

        let data = try manifest.encoded()
        let parsed = try Manifest.parse(from: data)

        #expect(parsed.entries.count == 2)
        #expect(parsed.entries["uuid-1"]?.s3Key == "originals/2024/01/uuid-1.heic")
        #expect(parsed.entries["uuid-2"]?.checksum == "sha256:bbb")
        #expect(parsed.entries["uuid-2"]?.size == nil)
    }

    @Test func tamperedIdentityKindFallsBackToLocal() throws {
        // Future or hand-rolled JSON containing an unknown identityKind value
        // must not take down the whole manifest decode. Single bad row falls
        // back to .local; siblings decode cleanly.
        let json = """
        {
          "version": 2,
          "entries": {
            "GOOD": {
              "uuid": "GOOD",
              "s3Key": "originals/2024/01/GOOD.heic",
              "checksum": "sha256:good",
              "backedUpAt": "2024-01-01T00:00:00Z",
              "identityKind": "cloud"
            },
            "TAMPER": {
              "uuid": "TAMPER",
              "s3Key": "originals/2024/01/TAMPER.heic",
              "checksum": "sha256:tamper",
              "backedUpAt": "2024-01-01T00:00:00Z",
              "identityKind": "WAT-IS-DIS"
            }
          }
        }
        """
        let data = Data(json.utf8)
        let parsed = try Manifest.parse(from: data)
        #expect(parsed.entries["GOOD"]?.identityKind == .cloud)
        #expect(parsed.entries["TAMPER"]?.identityKind == .local)
    }
}
