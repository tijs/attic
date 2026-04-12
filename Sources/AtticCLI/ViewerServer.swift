import AtticCore
import Foundation
import Hummingbird

/// API response for a paginated asset list.
struct AssetListResponse: ResponseEncodable {
    var assets: [AssetWithURL]
    var totalCount: Int
    var page: Int
    var pageSize: Int
}

/// Single asset with a pre-signed image URL.
struct AssetWithURL: Codable {
    var uuid: String
    var filename: String
    var dateCreated: String?
    var year: Int?
    var albums: [String]
    var isFavorite: Bool
    var isVideo: Bool
    var width: Int
    var height: Int
    var imageURL: String
}

/// API response for a single asset detail.
struct AssetDetailResponse: ResponseEncodable {
    var uuid: String
    var filename: String
    var dateCreated: String?
    var year: Int?
    var albums: [String]
    var isFavorite: Bool
    var isVideo: Bool
    var width: Int
    var height: Int
    var imageURL: String
}

/// API response for available filter values.
struct FilterOptionsResponse: ResponseEncodable {
    var years: [YearCount]
    var albums: [AlbumCount]
    var totalAssets: Int
    var totalPhotos: Int
    var totalVideos: Int
}

/// Localhost HTTP server for the photo viewer.
struct ViewerServer {
    let dataStore: ViewerDataStore
    let s3: S3Providing
    let thumbnailProvider: ThumbnailProviding?
    let port: Int

    init(
        dataStore: ViewerDataStore,
        s3: S3Providing,
        thumbnailProvider: ThumbnailProviding? = nil,
        port: Int = 0
    ) {
        self.dataStore = dataStore
        self.s3 = s3
        self.thumbnailProvider = thumbnailProvider
        self.port = port
    }

    func start(onReady: @escaping @Sendable (Int) -> Void = { _ in }) async throws {
        let router = buildRouter()
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port)),
            onServerRunning: { channel in
                let actualPort = channel.localAddress?.port ?? 8080
                onReady(actualPort)
            }
        )
        try await app.runService()
    }

    func buildRouter() -> Router<BasicRequestContext> {
        let router = Router()

        router.get("/") { _, _ -> Response in
            let html = loadViewerHTML()
            return Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: .init(byteBuffer: .init(string: html))
            )
        }

        router.get("/api/filters") { _, _ -> FilterOptionsResponse in
            let opts = await dataStore.filterOptions()
            return FilterOptionsResponse(
                years: opts.years,
                albums: opts.albums,
                totalAssets: opts.totalAssets,
                totalPhotos: opts.totalPhotos,
                totalVideos: opts.totalVideos
            )
        }

        router.get("/api/assets") { request, _ -> AssetListResponse in
            let params = request.uri.queryParameters
            let page = params.get("page", as: Int.self) ?? 1
            let pageSize = params.get("pageSize", as: Int.self) ?? 50
            let year = params.get("year", as: Int.self)
            let album = params.get("album", as: String.self)
            let favorites = params.get("favorites", as: Bool.self)
            let mediaType = params.get("type", as: String.self)

            let result = await dataStore.query(
                year: year, album: album, favorites: favorites,
                mediaType: mediaType, page: page, pageSize: pageSize
            )

            let assetsWithURLs = result.assets.map { asset in
                assetWithURL(asset, expires: 14400)
            }

            return AssetListResponse(
                assets: assetsWithURLs,
                totalCount: result.totalCount,
                page: result.page,
                pageSize: result.pageSize
            )
        }

        router.get("/api/assets/:uuid") { _, context -> Response in
            let uuid = try context.parameters.require("uuid")
            guard let asset = await dataStore.asset(uuid: uuid) else {
                return Response(status: .notFound)
            }

            let detail = AssetDetailResponse(
                uuid: asset.uuid,
                filename: asset.filename,
                dateCreated: asset.dateCreated,
                year: asset.year,
                albums: asset.albums,
                isFavorite: asset.isFavorite,
                isVideo: asset.isVideo,
                width: asset.width,
                height: asset.height,
                imageURL: s3.presignedURL(key: asset.s3Key, expires: 14400)
                    .absoluteString
            )

            let data = try JSONEncoder().encode(detail)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(data: data))
            )
        }

        if let thumbProvider = thumbnailProvider {
            router.get("/api/thumb/:uuid") { _, context -> Response in
                let uuid = try context.parameters.require("uuid")
                guard S3Paths.isValidUUID(uuid) else {
                    return Response(status: .badRequest)
                }
                do {
                    let data = try await thumbProvider.thumbnail(uuid: uuid)
                    return Response(
                        status: .ok,
                        headers: [
                            .contentType: "image/jpeg",
                            .cacheControl: "public, max-age=31536000, immutable",
                        ],
                        body: .init(byteBuffer: .init(data: data))
                    )
                } catch {
                    return Response(status: .notFound)
                }
            }
        }

        return router
    }

    private func assetWithURL(_ asset: AssetView, expires: Int) -> AssetWithURL {
        AssetWithURL(
            uuid: asset.uuid,
            filename: asset.filename,
            dateCreated: asset.dateCreated,
            year: asset.year,
            albums: asset.albums,
            isFavorite: asset.isFavorite,
            isVideo: asset.isVideo,
            width: asset.width,
            height: asset.height,
            imageURL: s3.presignedURL(key: asset.s3Key, expires: expires)
                .absoluteString
        )
    }
}

/// Load the embedded viewer HTML from the resource bundle.
func loadViewerHTML() -> String {
    guard let url = Bundle.module.url(forResource: "viewer", withExtension: "html"),
          let html = try? String(contentsOf: url, encoding: .utf8)
    else {
        return "<html><body><h1>Error: viewer.html not found in bundle</h1></body></html>"
    }
    return html
}
