import Foundation

/// Metadata returned by a HEAD request.
public struct S3ObjectMeta: Sendable {
    public var contentLength: Int
    public var contentType: String?

    public init(contentLength: Int, contentType: String? = nil) {
        self.contentLength = contentLength
        self.contentType = contentType
    }
}

/// An object listing entry from listObjects.
public struct S3ListObject: Sendable {
    public var key: String
    public var size: Int

    public init(key: String, size: Int) {
        self.key = key
        self.size = size
    }
}

/// Protocol for S3-compatible storage operations.
public protocol S3Providing: Sendable {
    /// Upload an object from data.
    func putObject(key: String, body: Data, contentType: String?) async throws

    /// Upload an object by streaming from a file URL (avoids loading into memory).
    func putObject(key: String, fileURL: URL, contentType: String?) async throws

    /// Download an object's contents.
    func getObject(key: String) async throws -> Data

    /// Get an object's metadata, or nil if it doesn't exist.
    func headObject(key: String) async throws -> S3ObjectMeta?

    /// List objects with a given prefix.
    func listObjects(prefix: String) async throws -> [S3ListObject]

    /// Generate a pre-signed URL for temporary direct access to an object.
    func presignedURL(key: String, expires: Int) -> URL
}

/// Convenience overloads.
public extension S3Providing {
    func putObject(key: String, body: Data) async throws {
        try await putObject(key: key, body: body, contentType: nil)
    }

    /// Default file upload: uses memory-mapped I/O. Real implementations may override.
    func putObject(key: String, fileURL: URL, contentType: String?) async throws {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        try await putObject(key: key, body: data, contentType: contentType)
    }
}
