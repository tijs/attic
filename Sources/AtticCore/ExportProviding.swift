import Foundation
import LadderKit

/// Abstraction over the photo export mechanism for testability.
///
/// The real implementation calls LadderKit's PhotoExporter directly.
/// Tests use MockExportProvider with pre-configured results.
public protocol ExportProviding: Sendable {
    /// Export a batch of assets by UUID. Returns results and errors.
    func exportBatch(uuids: [String]) async throws -> ExportResponse

    /// Pre-flight check: verify required permissions (Photos, Automation).
    /// Throws if permissions are missing.
    func checkPermissions() async throws
}

/// Errors from the export layer.
public enum ExportProviderError: Error, CustomStringConvertible {
    case timeout(seconds: Int)
    case permissionDenied(String)

    public var description: String {
        switch self {
        case .timeout(let seconds):
            "Export timed out after \(seconds)s"
        case .permissionDenied(let message):
            message
        }
    }

    public var isTimeout: Bool {
        if case .timeout = self { return true }
        return false
    }

    public var isPermission: Bool {
        if case .permissionDenied = self { return true }
        return false
    }
}

/// Extension-to-content-type lookup table.
private let contentTypeMap: [String: String] = [
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "heic": "image/heic",
    "png": "image/png",
    "tiff": "image/tiff",
    "gif": "image/gif",
    "mp4": "video/mp4",
    "mov": "video/quicktime",
    "m4v": "video/x-m4v",
    "avi": "video/x-msvideo",
    "orf": "image/x-olympus-orf",
]

/// Map a file extension to its MIME content type.
public func contentTypeForExtension(_ ext: String) -> String {
    contentTypeMap[ext] ?? "application/octet-stream"
}
