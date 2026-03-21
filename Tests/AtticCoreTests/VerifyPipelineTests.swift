import Testing
import Foundation
@testable import AtticCore

@Suite("VerifyPipeline")
struct VerifyPipelineTests {
    private func makeManifest(entries: [(uuid: String, s3Key: String, checksum: String)]) -> Manifest {
        var manifest = Manifest()
        for e in entries {
            manifest.markBackedUp(uuid: e.uuid, s3Key: e.s3Key, checksum: e.checksum)
        }
        return manifest
    }

    @Test func verifyReportsOKForExistingObjects() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(key: "originals/2024/01/uuid-1.heic", body: Data("photo".utf8))
        try await s3.putObject(key: "originals/2024/01/uuid-2.heic", body: Data("photo2".utf8))

        let manifest = makeManifest(entries: [
            (uuid: "uuid-1", s3Key: "originals/2024/01/uuid-1.heic", checksum: "sha256:abc"),
            (uuid: "uuid-2", s3Key: "originals/2024/01/uuid-2.heic", checksum: "sha256:def"),
        ])

        let report = try await runVerify(manifest: manifest, s3: s3)

        #expect(report.ok == 2)
        #expect(report.missing == 0)
        #expect(report.failed == 0)
    }

    @Test func verifyDetectsMissingObjects() async throws {
        let s3 = MockS3Provider()
        // Only put one of the two objects
        try await s3.putObject(key: "originals/2024/01/uuid-1.heic", body: Data("photo".utf8))

        let manifest = makeManifest(entries: [
            (uuid: "uuid-1", s3Key: "originals/2024/01/uuid-1.heic", checksum: "sha256:abc"),
            (uuid: "uuid-2", s3Key: "originals/2024/01/uuid-2.heic", checksum: "sha256:def"),
        ])

        let report = try await runVerify(manifest: manifest, s3: s3)

        #expect(report.ok == 1)
        #expect(report.missing == 1)
    }

    @Test func emptyManifestReturnsEmptyReport() async throws {
        let s3 = MockS3Provider()
        let manifest = Manifest()

        let report = try await runVerify(manifest: manifest, s3: s3)

        #expect(report.ok == 0)
        #expect(report.missing == 0)
        #expect(report.failed == 0)
    }

    @Test func verifyReportsErrorsForS3Failures() async throws {
        let s3 = FailingS3Provider()

        var manifest = Manifest()
        manifest.markBackedUp(uuid: "uuid-1", s3Key: "originals/2024/01/uuid-1.heic", checksum: "sha256:abc")

        let report = try await runVerify(manifest: manifest, s3: s3)

        #expect(report.ok == 0)
        #expect(report.missing == 0)
        #expect(report.failed == 1)
        #expect(report.errors.count == 1)
        #expect(report.errors.first?.uuid == "uuid-1")
    }
}

/// S3 provider that throws on headObject to test the error path.
private actor FailingS3Provider: S3Providing {
    func putObject(key: String, body: Data, contentType: String?) async throws {}
    func getObject(key: String) async throws -> Data { Data() }
    func headObject(key: String) async throws -> S3ObjectMeta? {
        throw FailingS3Error.networkError
    }
    func listObjects(prefix: String) async throws -> [S3ListObject] { [] }
}

private enum FailingS3Error: Error {
    case networkError
}
