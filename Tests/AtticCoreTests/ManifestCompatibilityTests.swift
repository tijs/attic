import Testing
import Foundation
@testable import AtticCore

@Suite("Manifest cross-version compatibility")
struct ManifestCompatibilityTests {
    /// A manifest JSON produced by the Deno CLI (v0.2.x format).
    /// The Swift version must be able to parse this exactly.
    static let denoManifestJSON = """
    {
      "entries": {
        "A1B2C3D4-E5F6-7890-ABCD-EF1234567890": {
          "uuid": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
          "s3Key": "originals/2024/01/A1B2C3D4-E5F6-7890-ABCD-EF1234567890.heic",
          "checksum": "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
          "backedUpAt": "2024-01-15T12:34:56Z",
          "size": 4194304
        },
        "DEADBEEF-CAFE-4321-BABE-FEEDFACE1234": {
          "uuid": "DEADBEEF-CAFE-4321-BABE-FEEDFACE1234",
          "s3Key": "originals/2023/12/DEADBEEF-CAFE-4321-BABE-FEEDFACE1234.mov",
          "checksum": "sha256:60303ae22b998861bce3b28f33eec1be758a213c86c93c076dbe9f558c11c752",
          "backedUpAt": "2024-02-20T08:15:00Z"
        }
      }
    }
    """

    @Test func parsesDenoManifestFormat() throws {
        let data = Data(Self.denoManifestJSON.utf8)
        let manifest = try Manifest.parse(from: data)

        #expect(manifest.entries.count == 2)

        let entry1 = manifest.entries["A1B2C3D4-E5F6-7890-ABCD-EF1234567890"]
        #expect(entry1 != nil)
        #expect(entry1?.s3Key == "originals/2024/01/A1B2C3D4-E5F6-7890-ABCD-EF1234567890.heic")
        #expect(entry1?.checksum == "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
        #expect(entry1?.backedUpAt == "2024-01-15T12:34:56Z")
        #expect(entry1?.size == 4194304)

        let entry2 = manifest.entries["DEADBEEF-CAFE-4321-BABE-FEEDFACE1234"]
        #expect(entry2 != nil)
        #expect(entry2?.size == nil) // Optional field, not present
    }

    @Test func swiftManifestRoundTripsToDenoCompatibleFormat() throws {
        var manifest = Manifest()
        manifest.markBackedUp(
            uuid: "uuid-1",
            s3Key: "originals/2024/06/uuid-1.heic",
            checksum: "sha256:abc123def456",
            size: 1024,
            backedUpAt: "2024-06-15T10:00:00Z"
        )

        // Encode and re-parse
        let data = try manifest.encoded()
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Verify structure matches Deno format
        let entries = parsed["entries"] as! [String: Any]
        let entry = entries["uuid-1"] as! [String: Any]

        #expect(entry["uuid"] as? String == "uuid-1")
        #expect(entry["s3Key"] as? String == "originals/2024/06/uuid-1.heic")
        #expect(entry["checksum"] as? String == "sha256:abc123def456")
        #expect(entry["backedUpAt"] as? String == "2024-06-15T10:00:00Z")
        #expect(entry["size"] as? Int == 1024)
    }

    @Test func swiftCanContinueDenoBackup() throws {
        // Parse a Deno manifest, add a Swift entry, re-encode, re-parse
        let data = Data(Self.denoManifestJSON.utf8)
        var manifest = try Manifest.parse(from: data)

        #expect(manifest.isBackedUp("A1B2C3D4-E5F6-7890-ABCD-EF1234567890"))
        #expect(!manifest.isBackedUp("NEW-UUID"))

        // Swift adds a new entry
        manifest.markBackedUp(
            uuid: "NEW-UUID",
            s3Key: "originals/2025/03/NEW-UUID.png",
            checksum: "sha256:newchecksum",
            size: 2048,
            backedUpAt: "2025-03-21T00:00:00Z"
        )

        // Round-trip
        let encoded = try manifest.encoded()
        let reloaded = try Manifest.parse(from: encoded)

        #expect(reloaded.entries.count == 3)
        #expect(reloaded.isBackedUp("A1B2C3D4-E5F6-7890-ABCD-EF1234567890"))
        #expect(reloaded.isBackedUp("DEADBEEF-CAFE-4321-BABE-FEEDFACE1234"))
        #expect(reloaded.isBackedUp("NEW-UUID"))

        // Original entries preserved exactly
        let original = reloaded.entries["A1B2C3D4-E5F6-7890-ABCD-EF1234567890"]
        #expect(original?.size == 4194304)
        #expect(original?.backedUpAt == "2024-01-15T12:34:56Z")
    }

    @Test func handlesEmptyManifestFromDeno() throws {
        let json = """
        { "entries": {} }
        """
        let manifest = try Manifest.parse(from: Data(json.utf8))
        #expect(manifest.entries.isEmpty)
    }
}
