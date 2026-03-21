import Testing
import Foundation
@testable import AtticCore

@Suite("Manifest")
struct ManifestTests {
    @Test func emptyManifest() {
        let manifest = Manifest()
        #expect(manifest.entries.isEmpty)
        #expect(!manifest.isBackedUp("any-uuid"))
    }

    @Test func markBackedUp() {
        var manifest = Manifest()
        manifest.markBackedUp(
            uuid: "test-uuid",
            s3Key: "originals/2024/01/test-uuid.heic",
            checksum: "sha256:abc123",
            size: 1024,
            backedUpAt: "2024-01-15T12:00:00Z"
        )

        #expect(manifest.isBackedUp("test-uuid"))
        #expect(!manifest.isBackedUp("other-uuid"))

        let entry = manifest.entries["test-uuid"]!
        #expect(entry.uuid == "test-uuid")
        #expect(entry.s3Key == "originals/2024/01/test-uuid.heic")
        #expect(entry.checksum == "sha256:abc123")
        #expect(entry.size == 1024)
        #expect(entry.backedUpAt == "2024-01-15T12:00:00Z")
    }

    @Test func markBackedUpDefaultsTimestamp() {
        var manifest = Manifest()
        manifest.markBackedUp(
            uuid: "test-uuid",
            s3Key: "originals/2024/01/test-uuid.heic",
            checksum: "sha256:abc123"
        )

        let entry = manifest.entries["test-uuid"]!
        #expect(!entry.backedUpAt.isEmpty)
    }

    @Test func encodeAndParseRoundTrip() throws {
        var manifest = Manifest()
        manifest.markBackedUp(
            uuid: "uuid-1",
            s3Key: "originals/2024/01/uuid-1.heic",
            checksum: "sha256:aaa",
            size: 500,
            backedUpAt: "2024-01-01T00:00:00Z"
        )
        manifest.markBackedUp(
            uuid: "uuid-2",
            s3Key: "originals/2024/02/uuid-2.jpg",
            checksum: "sha256:bbb",
            backedUpAt: "2024-02-01T00:00:00Z"
        )

        let data = try manifest.encoded()
        let parsed = try Manifest.parse(from: data)

        #expect(parsed.entries.count == 2)
        #expect(parsed.entries["uuid-1"]?.s3Key == "originals/2024/01/uuid-1.heic")
        #expect(parsed.entries["uuid-2"]?.checksum == "sha256:bbb")
        #expect(parsed.entries["uuid-2"]?.size == nil)
    }
}
