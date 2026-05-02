import Foundation

/// A single backed-up asset's record in the manifest.
public struct ManifestEntry: Codable, Sendable, Equatable {
    public var uuid: String
    public var s3Key: String
    public var checksum: String
    public var backedUpAt: String
    public var size: Int?
    /// The device-local UUID prefix that originally identified this asset
    /// before migration to a cloud identifier. Nil for entries that were
    /// already created with a cloud identifier as their canonical uuid.
    public var legacyLocalIdentifier: String?
    /// Whether `uuid` is a cloud identifier or a device-local fallback.
    /// v1 manifests decoded without this field default to `.local`.
    public var identityKind: IdentityKind

    public init(
        uuid: String,
        s3Key: String,
        checksum: String,
        backedUpAt: String,
        size: Int? = nil,
        legacyLocalIdentifier: String? = nil,
        identityKind: IdentityKind = .local,
    ) {
        self.uuid = uuid
        self.s3Key = s3Key
        self.checksum = checksum
        self.backedUpAt = backedUpAt
        self.size = size
        self.legacyLocalIdentifier = legacyLocalIdentifier
        self.identityKind = identityKind
    }

    private enum CodingKeys: String, CodingKey {
        case uuid, s3Key, checksum, backedUpAt, size
        case legacyLocalIdentifier, identityKind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        s3Key = try c.decode(String.self, forKey: .s3Key)
        checksum = try c.decode(String.self, forKey: .checksum)
        backedUpAt = try c.decode(String.self, forKey: .backedUpAt)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        legacyLocalIdentifier = try c.decodeIfPresent(String.self, forKey: .legacyLocalIdentifier)
        // Tampered or future identityKind values fall back to `.local` rather
        // than failing the entire manifest decode. A single bad row must not
        // take down `attic status` / `attic backup` for the whole library.
        if let raw = try c.decodeIfPresent(String.self, forKey: .identityKind) {
            identityKind = IdentityKind(rawValue: raw) ?? .local
        } else {
            identityKind = .local
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uuid, forKey: .uuid)
        try c.encode(s3Key, forKey: .s3Key)
        try c.encode(checksum, forKey: .checksum)
        try c.encode(backedUpAt, forKey: .backedUpAt)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(legacyLocalIdentifier, forKey: .legacyLocalIdentifier)
        try c.encode(identityKind, forKey: .identityKind)
    }
}

/// Current manifest schema version. v1 manifests decode without `version`
/// (default 1) and without per-entry identity fields; v2 manifests carry
/// cloud-stable identity in entry uuids and stamp this field explicitly.
public let currentManifestVersion: Int = 2

/// The backup manifest — maps UUID to ManifestEntry.
///
/// `version: 1` indicates a legacy manifest keyed by device-local UUIDs.
/// `version: 2` indicates a migrated manifest where entries with
/// `identityKind == .cloud` use stable cross-device identifiers.
public struct Manifest: Codable, Sendable {
    public var version: Int
    public var entries: [String: ManifestEntry]

    public init(version: Int = currentManifestVersion, entries: [String: ManifestEntry] = [:]) {
        self.version = version
        self.entries = entries
    }

    /// True for legacy manifests that have not been migrated to v2.
    public var isV1: Bool { version < currentManifestVersion }

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
        legacyLocalIdentifier: String? = nil,
        identityKind: IdentityKind = .local,
    ) {
        entries[uuid] = ManifestEntry(
            uuid: uuid,
            s3Key: s3Key,
            checksum: checksum,
            backedUpAt: backedUpAt ?? formatISO8601(Date()),
            size: size,
            legacyLocalIdentifier: legacyLocalIdentifier,
            identityKind: identityKind,
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version, entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entries = try c.decode([String: ManifestEntry].self, forKey: .entries)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(entries, forKey: .entries)
    }
}

/// S3 key where the shared manifest is stored.
public let manifestS3Key = "manifest.json"

/// S3 key for the v1 backup snapshot written before a v2 migration swap.
/// Always retained as a forensic / recovery artifact.
public let manifestV1BackupS3Key = "manifest.v1.json"

/// S3 key for the staged v2 manifest written before atomic swap. Deleted
/// after a successful swap.
public let manifestV2StagingS3Key = "manifest.v2.json"

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
