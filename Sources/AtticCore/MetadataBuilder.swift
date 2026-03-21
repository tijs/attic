import Foundation
import LadderKit

/// Per-asset metadata JSON uploaded to S3 at metadata/assets/{uuid}.json.
public struct AssetMetadata: Codable, Sendable {
    public var uuid: String
    public var originalFilename: String
    public var dateCreated: String?
    public var width: Int
    public var height: Int
    public var latitude: Double?
    public var longitude: Double?
    public var fileSize: Int?
    public var type: String?
    public var favorite: Bool
    public var title: String?
    public var description: String?
    public var albums: [AlbumRef]
    public var keywords: [String]
    public var people: [PersonRef]
    public var hasEdit: Bool
    public var editedAt: String?
    public var editor: String?
    public var s3Key: String
    public var checksum: String
    public var backedUpAt: String
}

/// Album reference for metadata JSON (matches Deno schema).
public struct AlbumRef: Codable, Sendable, Equatable {
    public var uuid: String
    public var title: String

    public init(uuid: String, title: String) {
        self.uuid = uuid
        self.title = title
    }
}

/// Person reference for metadata JSON (matches Deno schema).
public struct PersonRef: Codable, Sendable, Equatable {
    public var uuid: String
    public var displayName: String

    public init(uuid: String, displayName: String) {
        self.uuid = uuid
        self.displayName = displayName
    }
}

/// Build a metadata JSON object for upload to S3.
public func buildMetadataJSON(
    asset: AssetInfo,
    s3Key: String,
    checksum: String,
    backedUpAt: String
) -> AssetMetadata {
    AssetMetadata(
        uuid: asset.uuid,
        originalFilename: asset.originalFilename ?? "unknown",
        dateCreated: asset.creationDate.map { isoFormatter.string(from: $0) },
        width: asset.pixelWidth,
        height: asset.pixelHeight,
        latitude: asset.latitude,
        longitude: asset.longitude,
        fileSize: nil, // TODO: add when LadderKit has originalFileSize
        type: asset.uniformTypeIdentifier,
        favorite: asset.isFavorite,
        title: nil, // LadderKit AssetInfo doesn't have title
        description: asset.assetDescription,
        albums: asset.albums.map { AlbumRef(uuid: $0.identifier, title: $0.title) },
        keywords: asset.keywords,
        people: asset.people.map { PersonRef(uuid: $0.uuid, displayName: $0.displayName) },
        hasEdit: asset.hasEdit,
        editedAt: asset.editedAt.map { isoFormatter.string(from: $0) },
        editor: asset.editor,
        s3Key: s3Key,
        checksum: checksum,
        backedUpAt: backedUpAt
    )
}
