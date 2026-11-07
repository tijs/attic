import CryptoKit
import Foundation

public enum RestoreError: Error, CustomStringConvertible, Sendable {
    case invalid(String)
    public var description: String {
        switch self {
        case let .invalid(message): message
        }
    }
}

public struct RestoreFilters: Sendable {
    public var from: Date?
    public var before: Date?
    public var type: String?
    public var album: String?
    public var requiresMetadata: Bool {
        from != nil || before != nil || type != nil || album != nil
    }

    public init(from: Date? = nil, before: Date? = nil, type: String? = nil, album: String? = nil) {
        self.from = from
        self.before = before
        self.type = type
        self.album = album
    }
}

public struct RestoreItem: Codable, Sendable {
    public let key: String
    public let checksum: String
    public let expectedSize: Int64?
    public let uuids: [String]
    public let metadata: [AssetMetadata]
    public let metadataWarnings: Int
    public var id: String {
        Self.identifier(key)
    }

    public var relativePath: String {
        let rawSuffix = key.split(separator: "/").last?.split(separator: ".").last.map(String.init) ?? "bin"
        let suffix = rawSuffix.lowercased()
        let safe = !suffix.isEmpty && suffix.count <= 12 && suffix.utf8.allSatisfy {
            (97 ... 122).contains($0) || (48 ... 57).contains($0)
        }
        return "files/\(id).\(safe ? suffix : "bin")"
    }

    public static func identifier(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct RestorePlan: Sendable {
    public let sourceID: String
    public let items: [RestoreItem]
    public var metadataWarnings: Int {
        items.reduce(0) { $0 + $1.metadataWarnings }
    }
}

public struct RestoreReport: Sendable {
    public var restored = 0
    public var skipped = 0
    public var failed = 0
    public var pending = 0
    public var bytes: Int64 = 0
    public var imported = 0
    public var importFailed = 0
    public var importUncertain = 0
    public var errors: [String] = []
    public var successful: Bool {
        failed == 0 && pending == 0 && importFailed == 0 && importUncertain == 0
    }
}

public enum RestoreValidation {
    public static func checksum(_ value: String) throws -> String {
        guard value.hasPrefix("sha256:"), value.utf8.count == 71,
              value.dropFirst(7).utf8.allSatisfy({
                  (48 ... 57).contains($0) || (97 ... 102).contains($0) || (65 ... 70).contains($0)
              })
        else { throw RestoreError.invalid("Restore requires a valid SHA-256 checksum for every original") }
        return value.dropFirst(7).lowercased()
    }

    /// URLComponents.percentEncodedPath traps on malformed escapes: validate first.
    public static func objectKey(_ value: String) throws {
        guard S3Paths.isValidS3Key(value), !value.hasPrefix("/"), !value.isEmpty else {
            throw RestoreError.invalid("Unsafe backup object key")
        }
        let components = value.components(separatedBy: "/")
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.removingPercentEncoding != "." &&
                $0.removingPercentEncoding != ".."
        }) else { throw RestoreError.invalid("Unsafe backup object path") }
        let bytes = Array(value.utf8)
        let hex = Set("0123456789abcdefABCDEF".utf8)
        for index in bytes.indices where bytes[index] == 37 {
            guard index + 2 < bytes.count, hex.contains(bytes[index + 1]), hex.contains(bytes[index + 2]) else {
                throw RestoreError.invalid("Malformed percent escape in backup object key")
            }
        }
    }
}

public extension AtticConfig {
    var restoreSourceID: String {
        if let filesystem { return "filesystem:\(filesystem.volumeUUID):\(filesystem.targetID)" }
        let fields = [endpoint, region, bucket, String(pathStyle)].joined(separator: "\u{0}")
        return "s3:" + RestoreItem.identifier(fields)
    }
}
