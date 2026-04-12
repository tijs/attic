@testable import AtticCore
import CoreGraphics
import Foundation
import Testing

// MARK: - ThumbnailCache Tests

struct ThumbnailCacheTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func getReturnsNilForMissingUUID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ThumbnailCache(directory: dir)
        #expect(cache.get(uuid: "nonexistent") == nil)
    }

    @Test func putAndGetRoundTrips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ThumbnailCache(directory: dir)
        let data = Data("fake-jpeg".utf8)

        try cache.put(uuid: "test-uuid-123", data: data)
        let retrieved = cache.get(uuid: "test-uuid-123")
        #expect(retrieved == data)
    }

    @Test func putCreatesDirectoryIfNeeded() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(!FileManager.default.fileExists(atPath: dir.path))

        let cache = ThumbnailCache(directory: dir)
        try cache.put(uuid: "test-uuid", data: Data("data".utf8))

        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func getRejectsUnsafeUUID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ThumbnailCache(directory: dir)

        // Path traversal attempt
        #expect(cache.get(uuid: "../../../etc/passwd") == nil)
        #expect(cache.get(uuid: "uuid/with/slashes") == nil)
    }

    @Test func putIgnoresUnsafeUUID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ThumbnailCache(directory: dir)

        // Should silently do nothing
        try cache.put(uuid: "../../../bad", data: Data("data".utf8))
        #expect(cache.get(uuid: "../../../bad") == nil)
    }
}

// MARK: - S3Paths.thumbnailKey Tests

struct ThumbnailKeyTests {
    @Test func thumbnailKeyGeneratesCorrectPath() throws {
        let key = try S3Paths.thumbnailKey(uuid: "abc-123")
        #expect(key == "thumbnails/abc-123.jpg")
    }

    @Test func thumbnailKeyRejectsUnsafeUUID() {
        #expect(throws: S3PathError.self) {
            try S3Paths.thumbnailKey(uuid: "../../../etc")
        }
        #expect(throws: S3PathError.self) {
            try S3Paths.thumbnailKey(uuid: "uuid/with/slashes")
        }
    }
}

// MARK: - ImageThumbnailer Tests

struct ImageThumbnailerTests {
    @Test func thumbnailFromValidJPEGData() throws {
        // Create a minimal valid JPEG via CGImage
        let jpegData = try createTestJPEG(width: 800, height: 600)
        let thumb = try ImageThumbnailer.thumbnail(from: jpegData, maxDimension: 200)

        #expect(!thumb.isEmpty)
        // Verify it's JPEG (starts with FF D8)
        #expect(thumb[0] == 0xFF)
        #expect(thumb[1] == 0xD8)
    }

    @Test func thumbnailFromInvalidDataThrows() {
        let badData = Data("not an image".utf8)
        #expect(throws: ThumbnailError.self) {
            try ImageThumbnailer.thumbnail(from: badData)
        }
    }

    @Test func encodeJPEGProducesValidOutput() throws {
        let cgImage = try createTestCGImage(width: 100, height: 100)
        let data = try ImageThumbnailer.encodeJPEG(image: cgImage, quality: 0.8)

        #expect(!data.isEmpty)
        #expect(data[0] == 0xFF)
        #expect(data[1] == 0xD8)
    }

    /// Helper to create a test JPEG
    private func createTestJPEG(width: Int, height: Int) throws -> Data {
        let cgImage = try createTestCGImage(width: width, height: height)
        return try ImageThumbnailer.encodeJPEG(image: cgImage, quality: 0.9)
    }

    private func createTestCGImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else {
            throw ThumbnailError.decodeFailed("Could not create test CGContext")
        }
        ctx.setFillColor(red: 0.5, green: 0.3, blue: 0.8, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else {
            throw ThumbnailError.decodeFailed("Could not create test CGImage")
        }
        return image
    }
}

// MARK: - ThumbnailService Tests

struct ThumbnailServiceTests {
    private func makeAssetView(
        uuid: String,
        isVideo: Bool = false,
    ) -> AssetView {
        AssetView(
            uuid: uuid,
            filename: "\(uuid).heic",
            dateCreated: "2024-07-14T12:00:00Z",
            year: 2024,
            albums: [],
            isFavorite: false,
            isVideo: isVideo,
            width: 4032,
            height: 3024,
            s3Key: "originals/2024/07/\(uuid).heic",
        )
    }

    private func createTestJPEG() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: 100, height: 100,
            bitsPerComponent: 8, bytesPerRow: 400,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ),
            let image = ctx.makeImage()
        else {
            throw ThumbnailError.decodeFailed("Could not create test image")
        }
        return try ImageThumbnailer.encodeJPEG(image: image, quality: 0.8)
    }

    @Test func servesFromLocalCacheFirst() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = ThumbnailCache(directory: dir)
        let cachedData = Data("cached-thumbnail".utf8)
        try cache.put(uuid: "test-uuid", data: cachedData)

        let s3 = MockS3Provider()
        let dataStore = ViewerDataStore()

        let service = ThumbnailService(
            cache: cache, s3: s3, dataStore: dataStore,
        )

        let result = try await service.thumbnail(uuid: "test-uuid")
        #expect(result == cachedData)
        // Should not hit S3 at all
        let getCount = await s3.getCount
        #expect(getCount == 0)
    }

    @Test func servesFromS3ThumbnailWhenNotCachedLocally() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let thumbData = Data("s3-thumbnail".utf8)
        let s3 = MockS3Provider(objects: [
            "thumbnails/test-uuid.jpg": thumbData,
        ])
        let dataStore = ViewerDataStore()
        let cache = ThumbnailCache(directory: dir)

        let service = ThumbnailService(
            cache: cache, s3: s3, dataStore: dataStore,
        )

        let result = try await service.thumbnail(uuid: "test-uuid")
        #expect(result == thumbData)

        // Should also be written to local cache
        let cached = cache.get(uuid: "test-uuid")
        #expect(cached == thumbData)
    }

    @Test func generatesFromOriginalWhenNoThumbnailExists() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let originalJPEG = try createTestJPEG()
        let s3 = MockS3Provider(objects: [
            "originals/2024/07/photo-uuid.heic": originalJPEG,
        ])
        let dataStore = ViewerDataStore()
        let asset = makeAssetView(uuid: "photo-uuid")
        await dataStore.load(assets: [asset])

        let cache = ThumbnailCache(directory: dir)
        let service = ThumbnailService(
            cache: cache, s3: s3, dataStore: dataStore,
        )

        let result = try await service.thumbnail(uuid: "photo-uuid")
        #expect(!result.isEmpty)
        // Should be valid JPEG
        #expect(result[0] == 0xFF)
        #expect(result[1] == 0xD8)

        // Should be cached locally now
        let cached = cache.get(uuid: "photo-uuid")
        #expect(cached == result)

        // Should have been uploaded to S3 as thumbnail
        let s3Thumb = await s3.objects["thumbnails/photo-uuid.jpg"]
        #expect(s3Thumb != nil)
    }

    @Test func throwsNotFoundForUnknownUUID() async throws {
        let s3 = MockS3Provider()
        let dataStore = ViewerDataStore()
        let service = ThumbnailService(s3: s3, dataStore: dataStore)

        do {
            _ = try await service.thumbnail(uuid: "nonexistent")
            #expect(Bool(false), "Should have thrown")
        } catch let error as ThumbnailError {
            if case let .notFound(uuid) = error {
                #expect(uuid == "nonexistent")
            } else {
                #expect(Bool(false), "Wrong error case: \(error)")
            }
        }
    }

    @Test func deduplicatesInFlightRequests() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let originalJPEG = try createTestJPEG()
        let s3 = MockS3Provider(objects: [
            "originals/2024/07/dedup-uuid.heic": originalJPEG,
        ])
        let dataStore = ViewerDataStore()
        let asset = makeAssetView(uuid: "dedup-uuid")
        await dataStore.load(assets: [asset])

        let cache = ThumbnailCache(directory: dir)
        let service = ThumbnailService(
            cache: cache, s3: s3, dataStore: dataStore,
        )

        // Launch multiple concurrent requests for the same UUID
        async let r1 = service.thumbnail(uuid: "dedup-uuid")
        async let r2 = service.thumbnail(uuid: "dedup-uuid")

        let (result1, result2) = try await (r1, r2)
        #expect(result1 == result2)
    }
}
