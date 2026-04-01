import Foundation

/// A single backed-up asset's record in the manifest.
public struct ManifestEntry: Codable, Sendable, Equatable {
    public var uuid: String
    public var s3Key: String
    public var checksum: String
    public var backedUpAt: String
    public var size: Int?

    public init(
        uuid: String,
        s3Key: String,
        checksum: String,
        backedUpAt: String,
        size: Int? = nil,
    ) {
        self.uuid = uuid
        self.s3Key = s3Key
        self.checksum = checksum
        self.backedUpAt = backedUpAt
        self.size = size
    }
}

/// The backup manifest — maps UUID to ManifestEntry.
public struct Manifest: Codable, Sendable {
    public var entries: [String: ManifestEntry]

    public init(entries: [String: ManifestEntry] = [:]) {
        self.entries = entries
    }

    /// Check whether an asset has been backed up.
    public func isBackedUp(_ uuid: String) -> Bool {
        entries[uuid] != nil
    }

    /// Mark an asset as backed up (mutates in place).
    public mutating func markBackedUp(
        uuid: String,
        s3Key: String,
        checksum: String,
        size: Int? = nil,
        backedUpAt: String? = nil,
    ) {
        entries[uuid] = ManifestEntry(
            uuid: uuid,
            s3Key: s3Key,
            checksum: checksum,
            backedUpAt: backedUpAt ?? isoFormatter.string(from: Date()),
            size: size,
        )
    }
}

/// S3 key where the shared manifest is stored.
public let manifestS3Key = "manifest.json"

/// Protocol for loading and saving the manifest.
public protocol ManifestStoring: Sendable {
    func load() async throws -> Manifest
    func save(_ manifest: Manifest) async throws
}

// MARK: - Validation

public extension Manifest {
    /// Parse and validate manifest data.
    static func parse(from data: Data) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Encode manifest to JSON data.
    ///
    /// - Parameter sortedKeys: Use sorted keys for human readability (slower for large manifests).
    ///   Defaults to false for periodic saves; callers should pass true for final saves.
    func encoded(sortedKeys: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = sortedKeys ? [.prettyPrinted, .sortedKeys] : []
        var data = try encoder.encode(self)
        data.append(contentsOf: "\n".utf8)
        return data
    }
}
