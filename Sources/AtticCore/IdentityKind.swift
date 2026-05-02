import Foundation

/// Whether an asset record's `uuid` is a stable cloud identifier (works
/// across all devices in the same iCloud Photos library) or a device-local
/// identifier prefix (legacy v1 entries, or v2 entries for assets that
/// have no cloud counterpart).
///
/// Shared by ``ManifestEntry`` and ``AssetMetadata``. Lives in its own file
/// because both Manifest and MetadataBuilder reference it — leaving it in
/// `Manifest.swift` obscured the shared ownership.
public enum IdentityKind: String, Codable, Sendable, Equatable {
    case cloud
    case local
}
