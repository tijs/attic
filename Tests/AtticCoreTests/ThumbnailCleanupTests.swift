@testable import AtticCore
import Foundation
import Testing

/// In-memory S3 mock that injects a transient `deleteObject` failure on a
/// configured set of keys. Other operations delegate to a backing
/// `MockS3Provider`. Used to exercise partial-failure paths in
/// `runThumbnailCleanup`.
private actor FlakyDeleteS3Provider: S3Providing {
    private let backing: MockS3Provider
    private var failOnce: Set<String>

    init(backing: MockS3Provider, failOnce: Set<String>) {
        self.backing = backing
        self.failOnce = failOnce
    }

    func putObject(key: String, body: Data, contentType: String?) async throws {
        try await backing.putObject(key: key, body: body, contentType: contentType)
    }

    func putObject(key: String, fileURL: URL, contentType: String?) async throws {
        try await backing.putObject(key: key, fileURL: fileURL, contentType: contentType)
    }

    func getObject(key: String) async throws -> Data {
        try await backing.getObject(key: key)
    }

    func headObject(key: String) async throws -> S3ObjectMeta? {
        try await backing.headObject(key: key)
    }

    func listObjects(prefix: String) async throws -> [S3ListObject] {
        try await backing.listObjects(prefix: prefix)
    }

    nonisolated func presignedURL(key: String, expires: Int) -> URL {
        backing.presignedURL(key: key, expires: expires)
    }

    func deleteObject(key: String) async throws {
        if failOnce.remove(key) != nil {
            throw FlakyError.transient(key)
        }
        try await backing.deleteObject(key: key)
    }
}

private enum FlakyError: Error, CustomStringConvertible {
    case transient(String)

    var description: String {
        switch self {
        case let .transient(key):
            "transient delete failure on \(key)"
        }
    }
}

/// S3 mock whose `listObjects` throws — exercises the early-throw path.
private actor ListThrowingS3Provider: S3Providing {
    func putObject(key _: String, body _: Data, contentType _: String?) async throws {}
    func putObject(key _: String, fileURL _: URL, contentType _: String?) async throws {}
    func getObject(key _: String) async throws -> Data {
        Data()
    }

    func headObject(key _: String) async throws -> S3ObjectMeta? {
        nil
    }

    nonisolated func presignedURL(key: String, expires: Int) -> URL {
        URL(string: "http://mock/\(key)?\(expires)")!
    }

    func listObjects(prefix _: String) async throws -> [S3ListObject] {
        throw FlakyError.transient("list")
    }

    func deleteObject(key _: String) async throws {}
}

/// Scaleway returns NoSuchKey rather than an empty result when a never-used
/// prefix is listed. The retired thumbnails prefix must tolerate that shape.
private actor NoSuchKeyListS3Provider: S3Providing {
    func putObject(key _: String, body _: Data, contentType _: String?) async throws {}

    func putObject(key _: String, fileURL _: URL, contentType _: String?) async throws {}

    func getObject(key _: String) async throws -> Data {
        Data()
    }

    func headObject(key _: String) async throws -> S3ObjectMeta? {
        nil
    }

    func listObjects(prefix _: String) async throws -> [S3ListObject] {
        throw S3ClientError.s3Error(code: "NoSuchKey", message: "The specified key does not exist.")
    }

    nonisolated func presignedURL(key: String, expires: Int) -> URL {
        URL(string: "http://mock/\(key)?\(expires)")!
    }

    func deleteObject(key _: String) async throws {}
}

struct ThumbnailCleanupTests {
    private func seed(_ s3: MockS3Provider, count: Int, bytesEach: Int) async throws {
        for i in 0 ..< count {
            try await s3.putObject(
                key: "thumbnails/asset-\(i).jpg",
                body: Data(repeating: UInt8(i % 256), count: bytesEach),
                contentType: "image/jpeg",
            )
        }
        // Add a non-thumbnail to confirm prefix isolation.
        try await s3.putObject(
            key: "originals/2024/01/keep.heic",
            body: Data([0x42, 0x42]),
            contentType: nil,
        )
    }

    private let noopProgress: @Sendable (Int, Int) -> Void = { _, _ in }

    @Test func deletesAllThumbnailsOnApply() async throws {
        let s3 = MockS3Provider()
        try await seed(s3, count: 3, bytesEach: 100)

        let result = try await runThumbnailCleanup(
            s3: s3,
            dryRun: false,
            progress: noopProgress,
        )

        #expect(result.deleted == 3)
        #expect(result.bytes == 300)
        #expect(result.failed.isEmpty)

        let remaining = try await s3.listObjects(prefix: "thumbnails/")
        #expect(remaining.isEmpty)
        let originals = try await s3.listObjects(prefix: "originals/")
        #expect(originals.count == 1)
    }

    @Test func emptyPrefixReturnsZero() async throws {
        let s3 = MockS3Provider()
        let result = try await runThumbnailCleanup(
            s3: s3,
            dryRun: false,
            progress: noopProgress,
        )

        #expect(result.deleted == 0)
        #expect(result.bytes == 0)
        #expect(result.failed.isEmpty)
    }

    @Test func dryRunReportsButDoesNotDelete() async throws {
        let s3 = MockS3Provider()
        try await seed(s3, count: 3, bytesEach: 50)

        let result = try await runThumbnailCleanup(
            s3: s3,
            dryRun: true,
            progress: noopProgress,
        )

        #expect(result.deleted == 3)
        #expect(result.bytes == 150)
        #expect(result.failed.isEmpty)

        let remaining = try await s3.listObjects(prefix: "thumbnails/")
        #expect(remaining.count == 3)
    }

    @Test func collectsPerKeyFailuresAndContinues() async throws {
        let backing = MockS3Provider()
        try await seed(backing, count: 5, bytesEach: 10)
        let flaky = FlakyDeleteS3Provider(
            backing: backing,
            failOnce: ["thumbnails/asset-2.jpg"],
        )

        let result = try await runThumbnailCleanup(
            s3: flaky,
            dryRun: false,
            progress: noopProgress,
        )

        #expect(result.deleted == 4)
        #expect(result.failed.count == 1)
        #expect(result.failed["thumbnails/asset-2.jpg"] != nil)

        let remaining = try await backing.listObjects(prefix: "thumbnails/")
        #expect(remaining.map(\.key) == ["thumbnails/asset-2.jpg"])
    }

    @Test func listObjectsThrowsPropagatesAndDeletesNothing() async throws {
        let s3 = ListThrowingS3Provider()
        await #expect(throws: FlakyError.self) {
            _ = try await runThumbnailCleanup(
                s3: s3,
                dryRun: false,
                progress: { _, _ in },
            )
        }
    }

    @Test func noSuchKeyForNeverUsedThumbnailPrefixIsEmpty() async throws {
        let result = try await runThumbnailCleanup(
            s3: NoSuchKeyListS3Provider(),
            dryRun: false,
            progress: noopProgress,
        )

        #expect(result.deleted == 0)
        #expect(result.bytes == 0)
        #expect(result.failed.isEmpty)
    }

    @Test func reRunAfterPartialFailureCompletesCleanup() async throws {
        let backing = MockS3Provider()
        try await seed(backing, count: 3, bytesEach: 10)
        let flaky = FlakyDeleteS3Provider(
            backing: backing,
            failOnce: ["thumbnails/asset-1.jpg"],
        )

        let first = try await runThumbnailCleanup(s3: flaky, dryRun: false, progress: noopProgress)
        #expect(first.failed.count == 1)
        let afterFirst = try await backing.listObjects(prefix: "thumbnails/")
        #expect(afterFirst.count == 1)

        // Second run goes straight at the backing mock — flake already drained.
        let second = try await runThumbnailCleanup(s3: backing, dryRun: false, progress: noopProgress)
        #expect(second.deleted == 1)
        #expect(second.failed.isEmpty)
        let final = try await backing.listObjects(prefix: "thumbnails/")
        #expect(final.isEmpty)
    }
}
