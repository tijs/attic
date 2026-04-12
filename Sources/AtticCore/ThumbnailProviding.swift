import Foundation

/// Protocol for serving thumbnail image data by asset UUID.
public protocol ThumbnailProviding: Sendable {
    /// Returns JPEG thumbnail data for the given asset UUID.
    func thumbnail(uuid: String) async throws -> Data
}

/// Errors from the thumbnail system.
public enum ThumbnailError: Error, CustomStringConvertible {
    case notFound(String)
    case decodeFailed(String)
    case s3Failure(String, Error)

    public var description: String {
        switch self {
        case let .notFound(uuid):
            "Thumbnail: asset not found: \(uuid)"
        case let .decodeFailed(uuid):
            "Thumbnail: failed to decode image for: \(uuid)"
        case let .s3Failure(uuid, error):
            "Thumbnail: S3 error for \(uuid): \(error)"
        }
    }
}
