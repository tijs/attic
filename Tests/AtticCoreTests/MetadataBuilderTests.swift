@testable import AtticCore
import Foundation
import LadderKit
import Testing

struct MetadataBuilderTests {
    @Test func buildsMetadataFromAssetInfo() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2024-06-15T10:30:00Z"))
        let asset = AssetInfo(
            identifier: "ABC-123/L0/001",
            creationDate: date,
            kind: .photo,
            pixelWidth: 4032,
            pixelHeight: 3024,
            latitude: 52.3676,
            longitude: 4.9041,
            isFavorite: true,
            originalFilename: "IMG_001.HEIC",
            uniformTypeIdentifier: "public.heic",
            hasEdit: false,
            albums: [AlbumInfo(identifier: "album-1", title: "Vacation")],
            keywords: ["beach", "summer"],
            people: [PersonInfo(uuid: "person-1", displayName: "Alice")],
            assetDescription: "A sunny beach photo",
        )

        let metadata = buildMetadataJSON(
            asset: asset,
            s3Key: "originals/2024/06/ABC-123.heic",
            checksum: "sha256:abc123",
            backedUpAt: "2024-06-15T12:00:00Z",
        )

        #expect(metadata.uuid == "ABC-123")
        #expect(metadata.identityKind == .local)
        #expect(metadata.legacyLocalIdentifier == "ABC-123")
        #expect(metadata.originalFilename == "IMG_001.HEIC")
        #expect(metadata.dateCreated == "2024-06-15T10:30:00Z")
        #expect(metadata.width == 4032)
        #expect(metadata.height == 3024)
        #expect(metadata.latitude == 52.3676)
        #expect(metadata.longitude == 4.9041)
        #expect(metadata.favorite == true)
        #expect(metadata.description == "A sunny beach photo")
        #expect(metadata.albums.count == 1)
        #expect(metadata.albums[0].title == "Vacation")
        #expect(metadata.keywords == ["beach", "summer"])
        #expect(metadata.people.count == 1)
        #expect(metadata.people[0].displayName == "Alice")
        #expect(metadata.hasEdit == false)
        #expect(metadata.s3Key == "originals/2024/06/ABC-123.heic")
        #expect(metadata.checksum == "sha256:abc123")
        #expect(metadata.backedUpAt == "2024-06-15T12:00:00Z")
    }

    @Test func handlesNilOptionalFields() {
        let asset = AssetInfo(
            identifier: "XYZ-789/L0/001",
            creationDate: nil,
            kind: .video,
            pixelWidth: 1920,
            pixelHeight: 1080,
            latitude: nil,
            longitude: nil,
            isFavorite: false,
        )

        let metadata = buildMetadataJSON(
            asset: asset,
            s3Key: "originals/unknown/00/XYZ-789.mov",
            checksum: "sha256:def456",
            backedUpAt: "2024-01-01T00:00:00Z",
        )

        #expect(metadata.uuid == "XYZ-789")
        #expect(metadata.originalFilename == "unknown")
        #expect(metadata.dateCreated == nil)
        #expect(metadata.latitude == nil)
        #expect(metadata.longitude == nil)
        #expect(metadata.description == nil)
        #expect(metadata.albums.isEmpty)
        #expect(metadata.keywords.isEmpty)
        #expect(metadata.people.isEmpty)
    }

    @Test func recordsCloudIdentityWhenAssetCarriesCloudIdentifier() {
        let asset = AssetInfo(
            identifier: "LOCAL-ABC/L0/001",
            cloudIdentifier: "CLOUD-XYZ-999",
            creationDate: nil,
            kind: .photo,
            pixelWidth: 1, pixelHeight: 1,
            latitude: nil, longitude: nil,
            isFavorite: false,
        )
        let metadata = buildMetadataJSON(
            asset: asset,
            s3Key: "originals/2024/01/LOCAL-ABC.heic",
            checksum: "sha256:c",
            backedUpAt: "2024-01-01T00:00:00Z",
        )
        #expect(metadata.uuid == "CLOUD-XYZ-999")
        #expect(metadata.identityKind == .cloud)
        #expect(metadata.legacyLocalIdentifier == "LOCAL-ABC")
    }

    @Test func decodesLegacyMetadataJSONWithoutIdentityFields() throws {
        let legacyJSON = """
        {
            "uuid": "LEGACY-UUID",
            "originalFilename": "test.heic",
            "width": 100,
            "height": 100,
            "favorite": false,
            "albums": [],
            "keywords": [],
            "people": [],
            "hasEdit": false,
            "s3Key": "originals/2024/01/LEGACY-UUID.heic",
            "checksum": "sha256:c",
            "backedUpAt": "2024-01-01T00:00:00Z"
        }
        """
        let decoded = try JSONDecoder().decode(AssetMetadata.self, from: Data(legacyJSON.utf8))
        #expect(decoded.uuid == "LEGACY-UUID")
        #expect(decoded.identityKind == .local)
        #expect(decoded.legacyLocalIdentifier == nil)
    }

    @Test func decodesV2MetadataJSONWithIdentityFields() throws {
        let v2JSON = """
        {
            "uuid": "CLOUD-X",
            "originalFilename": "test.heic",
            "width": 100,
            "height": 100,
            "favorite": false,
            "albums": [],
            "keywords": [],
            "people": [],
            "hasEdit": false,
            "s3Key": "originals/2024/01/legacy-prefix.heic",
            "checksum": "sha256:c",
            "backedUpAt": "2024-01-01T00:00:00Z",
            "legacyLocalIdentifier": "legacy-prefix",
            "identityKind": "cloud"
        }
        """
        let decoded = try JSONDecoder().decode(AssetMetadata.self, from: Data(v2JSON.utf8))
        #expect(decoded.uuid == "CLOUD-X")
        #expect(decoded.identityKind == .cloud)
        #expect(decoded.legacyLocalIdentifier == "legacy-prefix")
    }

    @Test func tamperedIdentityKindFallsBackToLocal() throws {
        let json = """
        {
            "uuid": "X",
            "originalFilename": "f.heic",
            "width": 1, "height": 1,
            "favorite": false, "hasEdit": false,
            "albums": [], "keywords": [], "people": [],
            "s3Key": "originals/2024/01/X.heic",
            "checksum": "sha256:x",
            "backedUpAt": "2024-01-01T00:00:00Z",
            "identityKind": "wat"
        }
        """
        let decoded = try JSONDecoder().decode(AssetMetadata.self, from: Data(json.utf8))
        #expect(decoded.identityKind == .local)
    }

    @Test func encodeDecodeRoundTripWithV2FieldsPopulated() throws {
        let original = AssetMetadata(
            uuid: "CLOUD-Y",
            originalFilename: "y.heic",
            dateCreated: nil,
            width: 10, height: 20,
            latitude: nil, longitude: nil,
            fileSize: 1024,
            type: "photo",
            favorite: true,
            title: nil,
            description: nil,
            albums: [],
            keywords: [],
            people: [],
            hasEdit: false,
            editedAt: nil,
            editor: nil,
            s3Key: "originals/2024/01/Y.heic",
            checksum: "sha256:y",
            backedUpAt: "2024-01-01T00:00:00Z",
            legacyLocalIdentifier: "Y-LEGACY",
            identityKind: .cloud,
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AssetMetadata.self, from: data)
        #expect(decoded.uuid == "CLOUD-Y")
        #expect(decoded.legacyLocalIdentifier == "Y-LEGACY")
        #expect(decoded.identityKind == .cloud)
        #expect(decoded.width == 10)
        #expect(decoded.height == 20)
    }
}
