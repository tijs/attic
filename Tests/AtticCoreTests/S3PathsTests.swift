import Testing
import Foundation
@testable import AtticCore

@Suite("S3Paths")
struct S3PathsTests {
    @Test func originalKeyGeneratesCorrectPath() throws {
        let date = ISO8601DateFormatter().date(from: "2024-01-15T12:00:00Z")!
        let key = try S3Paths.originalKey(uuid: "abc-uuid", dateCreated: date, extension: "heic")
        #expect(key == "originals/2024/01/abc-uuid.heic")
    }

    @Test func originalKeyHandlesNilDate() throws {
        let key = try S3Paths.originalKey(uuid: "abc-uuid", dateCreated: nil, extension: "jpg")
        #expect(key == "originals/unknown/00/abc-uuid.jpg")
    }

    @Test func originalKeyStripsLeadingDot() throws {
        let date = ISO8601DateFormatter().date(from: "2024-03-01T00:00:00Z")!
        let key = try S3Paths.originalKey(uuid: "x", dateCreated: date, extension: ".HEIC")
        #expect(key == "originals/2024/03/x.heic")
    }

    @Test func originalKeyRejectsUnsafeUUID() {
        let date = ISO8601DateFormatter().date(from: "2024-01-15T12:00:00Z")!
        #expect(throws: S3PathError.self) {
            try S3Paths.originalKey(uuid: "../../../etc", dateCreated: date, extension: "heic")
        }
        #expect(throws: S3PathError.self) {
            try S3Paths.originalKey(uuid: "uuid/with/slashes", dateCreated: date, extension: "heic")
        }
    }

    @Test func originalKeyRejectsUnsafeExtension() {
        let date = ISO8601DateFormatter().date(from: "2024-01-15T12:00:00Z")!
        #expect(throws: S3PathError.self) {
            try S3Paths.originalKey(uuid: "abc", dateCreated: date, extension: "h/e")
        }
    }

    @Test func metadataKeyGeneratesCorrectPath() throws {
        let key = try S3Paths.metadataKey(uuid: "abc-uuid")
        #expect(key == "metadata/assets/abc-uuid.json")
    }

    @Test func metadataKeyRejectsUnsafeUUID() {
        #expect(throws: S3PathError.self) {
            try S3Paths.metadataKey(uuid: "../escape")
        }
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
}
