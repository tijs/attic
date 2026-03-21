import Testing
import Foundation
import LadderKit
@testable import AtticCore

@Suite("MetadataBuilder")
struct MetadataBuilderTests {
    @Test func buildsMetadataFromAssetInfo() {
        let date = ISO8601DateFormatter().date(from: "2024-06-15T10:30:00Z")!
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
            assetDescription: "A sunny beach photo"
        )

        let metadata = buildMetadataJSON(
            asset: asset,
            s3Key: "originals/2024/06/ABC-123.heic",
            checksum: "sha256:abc123",
            backedUpAt: "2024-06-15T12:00:00Z"
        )

        #expect(metadata.uuid == "ABC-123")
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
            isFavorite: false
        )

        let metadata = buildMetadataJSON(
            asset: asset,
            s3Key: "originals/unknown/00/XYZ-789.mov",
            checksum: "sha256:def456",
            backedUpAt: "2024-01-01T00:00:00Z"
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
}
