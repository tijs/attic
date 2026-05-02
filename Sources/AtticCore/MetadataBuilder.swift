import Foundation
import LadderKit

/// Per-asset metadata JSON uploaded to S3 at metadata/assets/{uuid}.json.
///
/// `legacyLocalIdentifier` and `identityKind` track whether the canonical
/// `uuid` is a cross-device cloud identifier or a device-local fallback.
/// Legacy v1 metadata JSON files (without these fields) decode with
/// `identityKind == .local` and `legacyLocalIdentifier == nil`.
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
    public var legacyLocalIdentifier: String?
    public var identityKind: IdentityKind

    public init(
        uuid: String,
        originalFilename: String,
        dateCreated: String?,
        width: Int,
        height: Int,
        latitude: Double?,
        longitude: Double?,
        fileSize: Int?,
        type: String?,
        favorite: Bool,
        title: String?,
        description: String?,
        albums: [AlbumRef],
        keywords: [String],
        people: [PersonRef],
        hasEdit: Bool,
        editedAt: String?,
        editor: String?,
        s3Key: String,
        checksum: String,
        backedUpAt: String,
        legacyLocalIdentifier: String? = nil,
        identityKind: IdentityKind = .local,
    ) {
        self.uuid = uuid
        self.originalFilename = originalFilename
        self.dateCreated = dateCreated
        self.width = width
        self.height = height
        self.latitude = latitude
        self.longitude = longitude
        self.fileSize = fileSize
        self.type = type
        self.favorite = favorite
        self.title = title
        self.description = description
        self.albums = albums
        self.keywords = keywords
        self.people = people
        self.hasEdit = hasEdit
        self.editedAt = editedAt
        self.editor = editor
        self.s3Key = s3Key
        self.checksum = checksum
        self.backedUpAt = backedUpAt
        self.legacyLocalIdentifier = legacyLocalIdentifier
        self.identityKind = identityKind
    }

    private enum CodingKeys: String, CodingKey {
        case uuid, originalFilename, dateCreated, width, height, latitude, longitude
        case fileSize, type, favorite, title, description, albums, keywords, people
        case hasEdit, editedAt, editor, s3Key, checksum, backedUpAt
        case legacyLocalIdentifier, identityKind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        originalFilename = try c.decode(String.self, forKey: .originalFilename)
        dateCreated = try c.decodeIfPresent(String.self, forKey: .dateCreated)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        fileSize = try c.decodeIfPresent(Int.self, forKey: .fileSize)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        albums = try c.decodeIfPresent([AlbumRef].self, forKey: .albums) ?? []
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        people = try c.decodeIfPresent([PersonRef].self, forKey: .people) ?? []
        hasEdit = try c.decodeIfPresent(Bool.self, forKey: .hasEdit) ?? false
        editedAt = try c.decodeIfPresent(String.self, forKey: .editedAt)
        editor = try c.decodeIfPresent(String.self, forKey: .editor)
        s3Key = try c.decode(String.self, forKey: .s3Key)
        checksum = try c.decode(String.self, forKey: .checksum)
        backedUpAt = try c.decodeIfPresent(String.self, forKey: .backedUpAt) ?? ""
        legacyLocalIdentifier = try c.decodeIfPresent(String.self, forKey: .legacyLocalIdentifier)
        identityKind = try c.decodeIfPresent(IdentityKind.self, forKey: .identityKind) ?? .local
    }
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
    backedUpAt: String,
) -> AssetMetadata {
    let identityKind: IdentityKind = asset.cloudIdentifier != nil ? .cloud : .local
    return AssetMetadata(
        uuid: asset.uuid,
        originalFilename: asset.originalFilename ?? "unknown",
        dateCreated: asset.creationDate.map { formatISO8601($0) },
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
        editedAt: asset.editedAt.map { formatISO8601($0) },
        editor: asset.editor,
        s3Key: s3Key,
        checksum: checksum,
        backedUpAt: backedUpAt,
        legacyLocalIdentifier: asset.legacyLocalIdentifier,
        identityKind: identityKind,
    )
}
