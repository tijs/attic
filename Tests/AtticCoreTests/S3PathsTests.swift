@testable import AtticCore
import Foundation
import Testing

struct S3PathsTests {
    @Test func originalKeyGeneratesCorrectPath() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2024-01-15T12:00:00Z"))
        let key = try S3Paths.originalKey(uuid: "abc-uuid", dateCreated: date, extension: "heic")
        #expect(key == "originals/2024/01/abc-uuid.heic")
    }

    @Test func originalKeyHandlesNilDate() throws {
        let key = try S3Paths.originalKey(uuid: "abc-uuid", dateCreated: nil, extension: "jpg")
        #expect(key == "originals/unknown/00/abc-uuid.jpg")
    }

    @Test func originalKeyStripsLeadingDot() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2024-03-01T00:00:00Z"))
        let key = try S3Paths.originalKey(uuid: "x", dateCreated: date, extension: ".HEIC")
        #expect(key == "originals/2024/03/x.heic")
    }

    @Test func originalKeyEncodesPathReservedCharactersInUUID() throws {
        // PhotoKit cloud IDs contain `/` (base64 alphabet) so the validator
        // must accept it. Safety comes from percent-encoding the uuid into
        // a single path component — no raw `/` survives past the prefix.
        let date = try #require(ISO8601DateFormatter().date(from: "2024-01-15T12:00:00Z"))
        let key1 = try S3Paths.originalKey(uuid: "../../../etc", dateCreated: date, extension: "heic")
        #expect(key1 == "originals/2024/01/..%2F..%2F..%2Fetc.heic")
        let key2 = try S3Paths.originalKey(uuid: "uuid/with/slashes", dateCreated: date, extension: "heic")
        #expect(key2 == "originals/2024/01/uuid%2Fwith%2Fslashes.heic")
    }

    @Test func originalKeyRejectsUnsafeExtension() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2024-01-15T12:00:00Z"))
        #expect(throws: S3PathError.self) {
            try S3Paths.originalKey(uuid: "abc", dateCreated: date, extension: "h/e")
        }
    }

    @Test func metadataKeyGeneratesCorrectPath() throws {
        let key = try S3Paths.metadataKey(uuid: "abc-uuid")
        #expect(key == "metadata/assets/abc-uuid.json")
    }

    @Test func metadataKeyEncodesPathReservedCharactersInUUID() throws {
        let key = try S3Paths.metadataKey(uuid: "../escape")
        #expect(key == "metadata/assets/..%2Fescape.json")
    }

    @Test func extensionFromUTIMapsKnownTypes() {
        #expect(S3Paths.extensionFromUTIOrFilename(uti: "public.heic", filename: "IMG.HEIC") == "heic")
        #expect(S3Paths.extensionFromUTIOrFilename(uti: "public.jpeg", filename: "IMG.JPG") == "jpg")
        #expect(S3Paths.extensionFromUTIOrFilename(uti: "com.apple.quicktime-movie", filename: "VID.MOV") == "mov")
    }

    @Test func extensionFromUTIFallsBackToFilename() {
        #expect(S3Paths.extensionFromUTIOrFilename(uti: "unknown.uti", filename: "photo.webp") == "webp")
    }

    @Test func extensionFromUTIReturnsBinAsLastResort() {
        #expect(S3Paths.extensionFromUTIOrFilename(uti: nil, filename: "noext") == "bin")
    }

    @Test func metadataKeyEncodesCloudIdentifierWithColons() throws {
        // PHCloudIdentifier.stringValue includes colons. Regression for
        // beta.8 bug where the validator rejected them and migration aborted.
        // Beta.10: colons are percent-encoded into the path component so
        // the structural separators after `metadata/assets/` stay
        // unambiguous.
        let cloudID = "41C24A89-1280-4C14-BF5E-E93545843128:001:AaiU4soYcBEybZPj3zsS91dxDF42"
        let key = try S3Paths.metadataKey(uuid: cloudID)
        let expected = "metadata/assets/\(S3Paths.encodeUUIDComponent(cloudID)).json"
        #expect(key == expected)
        #expect(!key.dropFirst("metadata/assets/".count).contains(":"))
    }

    @Test func uuidValidatorAcceptsPhotoKitAlphabet() {
        // Cloud IDs use the standard base64 alphabet (`+`, `/`, `=`) plus
        // colons. The validator allows them; path safety comes from
        // percent-encoding before key construction.
        #expect(S3Paths.isValidUUID("foo/bar"))
        #expect(S3Paths.isValidUUID("../escape"))
        #expect(S3Paths.isValidUUID("UUID:001:base64part"))
        #expect(S3Paths.isValidUUID("UUID:001:Zk+gHi/123=="))
    }

    @Test func uuidValidatorRejectsControlAndSpace() {
        #expect(!S3Paths.isValidUUID("a b"))
        #expect(!S3Paths.isValidUUID("a\nb"))
        #expect(!S3Paths.isValidUUID(""))
    }
}
