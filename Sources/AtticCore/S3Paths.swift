import Foundation
import UniformTypeIdentifiers

/// S3 key generation and path safety for photo backup storage.
public enum S3Paths {
    // MARK: - Validation patterns

    private nonisolated(unsafe) static let uuidPattern = /^[A-Za-z0-9._\-]+$/
    private nonisolated(unsafe) static let s3KeyPattern = /^[A-Za-z0-9\/._\-]+$/
    private nonisolated(unsafe) static let extPattern = /^[a-z0-9]+$/

    /// Normalize extensions where the system canonical form differs from convention.
    private static let extensionOverrides: [String: String] = [
        "jpeg": "jpg",
    ]

    /// Resolve a UTI string to its preferred file extension using the system type database.
    private static func extensionFromUTI(_ uti: String) -> String? {
        guard let ext = UTType(uti)?.preferredFilenameExtension else { return nil }
        return extensionOverrides[ext] ?? ext
    }

    // MARK: - Key generation

    /// UTC calendar for date component extraction — hoisted to avoid per-call allocation.
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// Generate S3 key for an original photo/video file.
    public static func originalKey(
        uuid: String,
        dateCreated: Date?,
        extension ext: String,
    ) throws -> String {
        try assertSafeUUID(uuid)
        let cleanExt = ext.lowercased().trimmingPrefix(".")
        let extString = String(cleanExt)
        try assertSafeExtension(extString)

        let year: String
        let month: String
        if let date = dateCreated {
            let components = utcCalendar.dateComponents([.year, .month], from: date)
            year = String(components.year!)
            month = String(format: "%02d", components.month!)
        } else {
            year = "unknown"
            month = "00"
        }

        return "originals/\(year)/\(month)/\(uuid).\(extString)"
    }

    /// Generate S3 key for an asset's metadata JSON.
    public static func metadataKey(uuid: String) throws -> String {
        try assertSafeUUID(uuid)
        return "metadata/assets/\(uuid).json"
    }

    /// Generate S3 key for an asset's thumbnail JPEG.
    public static func thumbnailKey(uuid: String) throws -> String {
        try assertSafeUUID(uuid)
        return "thumbnails/\(uuid).jpg"
    }

    /// Extract file extension from a UTI or filename.
    public static func extensionFromUTIOrFilename(
        uti: String?,
        filename: String,
    ) -> String {
        if let uti, let ext = extensionFromUTI(uti) {
            return ext
        }

        if let dotIndex = filename.lastIndex(of: ".") {
            let afterDot = filename[filename.index(after: dotIndex)...]
            if !afterDot.isEmpty {
                return afterDot.lowercased()
            }
        }

        return "bin"
    }

    // MARK: - Validation

    /// Whether a string looks like a valid asset UUID (alphanumeric, dots, hyphens, underscores).
    public static func isValidUUID(_ value: String) -> Bool {
        value.wholeMatch(of: uuidPattern) != nil
    }

    /// Whether a string looks like a valid S3 key (alphanumeric, slashes, dots, hyphens, underscores).
    public static func isValidS3Key(_ value: String) -> Bool {
        value.wholeMatch(of: s3KeyPattern) != nil
    }

    private static func assertSafeUUID(_ uuid: String) throws {
        guard isValidUUID(uuid) else {
            throw S3PathError.unsafeUUID(uuid)
        }
    }

    private static func assertSafeExtension(_ ext: String) throws {
        guard ext.wholeMatch(of: extPattern) != nil else {
            throw S3PathError.unsafeExtension(ext)
        }
    }
}

/// Errors from S3 path generation.
public enum S3PathError: Error, CustomStringConvertible {
    case unsafeUUID(String)
    case unsafeExtension(String)

    public var description: String {
        switch self {
        case let .unsafeUUID(value):
            "Unsafe UUID for S3 key: \(value)"
        case let .unsafeExtension(value):
            "Unsafe extension for S3 key: \(value)"
        }
    }
}
