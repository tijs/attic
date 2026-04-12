@testable import AtticCore
import Foundation
import Testing

@Suite
struct ViewerDataStoreTests {
    // MARK: - Test helpers

    private func makeAssetView(
        uuid: String,
        year: Int? = 2024,
        albums: [String] = [],
        isFavorite: Bool = false,
        isVideo: Bool = false
    ) -> AssetView {
        AssetView(
            uuid: uuid,
            filename: "\(uuid).heic",
            dateCreated: year.map { "\($0)-07-14T12:00:00Z" },
            year: year,
            albums: albums,
            isFavorite: isFavorite,
            isVideo: isVideo,
            width: 4032,
            height: 3024,
            s3Key: "originals/\(year ?? 0)/07/\(uuid).heic"
        )
    }

    // MARK: - Query tests

    @Test func queryReturnsAllAssetsUnfiltered() async {
        let store = ViewerDataStore()
        let assets = (1...5).map { makeAssetView(uuid: "uuid-\($0)") }
        await store.load(assets: assets)

        let result = await store.query()
        #expect(result.totalCount == 5)
        #expect(result.assets.count == 5)
        #expect(result.page == 1)
    }

    @Test func queryFiltersByYear() async {
        let store = ViewerDataStore()
        let assets = [
            makeAssetView(uuid: "a", year: 2023),
            makeAssetView(uuid: "b", year: 2024),
            makeAssetView(uuid: "c", year: 2024),
        ]
        await store.load(assets: assets)

        let result = await store.query(year: 2024)
        #expect(result.totalCount == 2)
        #expect(result.assets.allSatisfy { $0.year == 2024 })
    }

    @Test func queryFiltersByAlbum() async {
        let store = ViewerDataStore()
        let assets = [
            makeAssetView(uuid: "a", albums: ["Vacation"]),
            makeAssetView(uuid: "b", albums: ["Work"]),
            makeAssetView(uuid: "c", albums: ["Vacation", "Favorites"]),
        ]
        await store.load(assets: assets)

        let result = await store.query(album: "Vacation")
        #expect(result.totalCount == 2)
    }

    @Test func queryFiltersByFavorites() async {
        let store = ViewerDataStore()
        let assets = [
            makeAssetView(uuid: "a", isFavorite: true),
            makeAssetView(uuid: "b", isFavorite: false),
            makeAssetView(uuid: "c", isFavorite: true),
        ]
        await store.load(assets: assets)

        let result = await store.query(favorites: true)
        #expect(result.totalCount == 2)
        #expect(result.assets.allSatisfy { $0.isFavorite })
    }

    @Test func queryFiltersByMediaType() async {
        let store = ViewerDataStore()
        let assets = [
            makeAssetView(uuid: "a", isVideo: false),
            makeAssetView(uuid: "b", isVideo: true),
            makeAssetView(uuid: "c", isVideo: false),
        ]
        await store.load(assets: assets)

        let photos = await store.query(mediaType: "photo")
        #expect(photos.totalCount == 2)

        let videos = await store.query(mediaType: "video")
        #expect(videos.totalCount == 1)
    }

    @Test func queryPaginates() async {
        let store = ViewerDataStore()
        let assets = (1...10).map { makeAssetView(uuid: "uuid-\($0)") }
        await store.load(assets: assets)

        let page1 = await store.query(page: 1, pageSize: 3)
        #expect(page1.assets.count == 3)
        #expect(page1.totalCount == 10)

        let page4 = await store.query(page: 4, pageSize: 3)
        #expect(page4.assets.count == 1)
    }

    @Test func queryBeyondLastPageReturnsEmpty() async {
        let store = ViewerDataStore()
        let assets = [makeAssetView(uuid: "a")]
        await store.load(assets: assets)

        let result = await store.query(page: 5, pageSize: 50)
        #expect(result.assets.isEmpty)
        #expect(result.totalCount == 1)
    }

    @Test func queryCombinesMultipleFilters() async {
        let store = ViewerDataStore()
        let assets = [
            makeAssetView(uuid: "a", year: 2024, albums: ["Vacation"], isFavorite: true),
            makeAssetView(uuid: "b", year: 2024, albums: ["Vacation"], isFavorite: false),
            makeAssetView(uuid: "c", year: 2023, albums: ["Vacation"], isFavorite: true),
        ]
        await store.load(assets: assets)

        let result = await store.query(year: 2024, album: "Vacation", favorites: true)
        #expect(result.totalCount == 1)
        #expect(result.assets.first?.uuid == "a")
    }

    // MARK: - Filter options

    @Test func filterOptionsReflectsLoadedData() async {
        let store = ViewerDataStore()
        let assets = [
            makeAssetView(uuid: "a", year: 2024, albums: ["Vacation"], isVideo: false),
            makeAssetView(uuid: "b", year: 2024, albums: ["Work"], isVideo: true),
            makeAssetView(uuid: "c", year: 2023, albums: ["Vacation"], isVideo: false),
        ]
        await store.load(assets: assets)

        let opts = await store.filterOptions()
        #expect(opts.totalAssets == 3)
        #expect(opts.totalPhotos == 2)
        #expect(opts.totalVideos == 1)
        #expect(opts.years.count == 2)
        #expect(opts.albums.count == 2)
    }

    // MARK: - Edge cases

    @Test func emptyManifestLoadsNothing() async {
        let store = ViewerDataStore()
        let s3 = MockS3Provider()
        let manifest = Manifest()

        await store.load(manifest: manifest, s3: s3)

        let result = await store.query()
        #expect(result.totalCount == 0)
        #expect(result.assets.isEmpty)
    }

    @Test func corruptMetadataIsSkipped() async {
        let store = ViewerDataStore()
        let s3 = MockS3Provider(objects: [
            "metadata/assets/good-uuid.json": try! JSONEncoder().encode(
                AssetMetadata(
                    uuid: "good-uuid", originalFilename: "IMG.HEIC",
                    dateCreated: "2024-01-15T12:00:00Z",
                    width: 4032, height: 3024,
                    latitude: nil, longitude: nil, fileSize: nil,
                    type: "public.heic", favorite: false,
                    title: nil, description: nil,
                    albums: [], keywords: [], people: [],
                    hasEdit: false, editedAt: nil, editor: nil,
                    s3Key: "originals/2024/01/good-uuid.heic",
                    checksum: "sha256:abc", backedUpAt: "2024-01-15T12:00:00Z"
                )
            ),
            "metadata/assets/bad-uuid.json": Data("not json".utf8),
        ])

        var manifest = Manifest()
        manifest.entries["good-uuid"] = ManifestEntry(
            uuid: "good-uuid", s3Key: "originals/2024/01/good-uuid.heic",
            checksum: "sha256:abc", backedUpAt: "2024-01-15T12:00:00Z"
        )
        manifest.entries["bad-uuid"] = ManifestEntry(
            uuid: "bad-uuid", s3Key: "originals/2024/01/bad-uuid.heic",
            checksum: "sha256:def", backedUpAt: "2024-01-15T12:00:00Z"
        )

        await store.load(manifest: manifest, s3: s3)

        let result = await store.query()
        #expect(result.totalCount == 1)
        #expect(result.assets.first?.uuid == "good-uuid")
    }

    @Test func assetLookupByUUID() async {
        let store = ViewerDataStore()
        let assets = [makeAssetView(uuid: "target")]
        await store.load(assets: assets)

        let found = await store.asset(uuid: "target")
        #expect(found != nil)
        #expect(found?.uuid == "target")

        let missing = await store.asset(uuid: "nonexistent")
        #expect(missing == nil)
    }
}
