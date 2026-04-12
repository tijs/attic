import Foundation
import LadderKit
import UniformTypeIdentifiers

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
        case let .timeout(seconds):
            "Export timed out after \(seconds)s"
        case let .permissionDenied(message):
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

/// Map a file extension to its MIME content type using the system type database.
public func contentTypeForExtension(_ ext: String) -> String {
    if let utType = UTType(filenameExtension: ext),
       let mimeType = utType.preferredMIMEType {
        return mimeType
    }
    return "application/octet-stream"
}
