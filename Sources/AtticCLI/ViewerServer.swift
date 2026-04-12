import AtticCore
import Foundation
import Hummingbird
import HummingbirdCore

/// API response for a paginated asset list.
struct AssetListResponse: ResponseEncodable {
    var assets: [AssetResponse]
    var totalCount: Int
    var page: Int
    var pageSize: Int
}

/// Single asset with a pre-signed image URL (used for both list and detail endpoints).
struct AssetResponse: Codable, ResponseEncodable {
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

/// Localhost HTTP server for the photo viewer.
struct ViewerServer {
    let dataStore: ViewerDataStore
    let s3: S3Providing
    let thumbnailProvider: ThumbnailProviding
    let port: Int

    init(
        dataStore: ViewerDataStore,
        s3: S3Providing,
        thumbnailProvider: ThumbnailProviding,
        port: Int = 0,
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
            },
        )
        try await app.runService()
    }

    // swiftlint:disable:next line_length
    private static let csp = "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' https://*.amazonaws.com; media-src 'self' https://*.amazonaws.com; font-src 'self'; connect-src 'self'"

    func buildRouter() -> Router<BasicRequestContext> {
        let router = Router()
        addHTMLRoute(router)
        addAPIRoutes(router)
        return router
    }

    private func addHTMLRoute(_ router: Router<BasicRequestContext>) {
        router.get("/") { _, _ -> Response in
            let html = loadViewerHTML()
            return Response(
                status: .ok,
                headers: [
                    .contentType: "text/html; charset=utf-8",
                    .init("X-Content-Type-Options")!: "nosniff",
                    .init("X-Frame-Options")!: "DENY",
                    .init("Content-Security-Policy")!: Self.csp,
                ],
                body: .init(byteBuffer: .init(string: html)),
            )
        }
    }

    private func addAPIRoutes(_ router: Router<BasicRequestContext>) {
        router.get("/api/filters") { request, _ -> Response in
            let params = request.uri.queryParameters
            let year = params.get("year", as: Int.self)
            let album = decodedParam(request.uri, "album")
            let favorites = params.get("favorites", as: Bool.self)
            let mediaType = params.get("type", as: String.self)

            let opts = await dataStore.filterOptions(
                year: year, album: album, favorites: favorites, mediaType: mediaType,
            )
            let data = try JSONEncoder().encode(opts)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(data: data)),
            )
        }

        router.get("/api/assets") { request, _ -> AssetListResponse in
            let params = request.uri.queryParameters
            let page = max(params.get("page", as: Int.self) ?? 1, 1)
            let pageSize = min(max(params.get("pageSize", as: Int.self) ?? 50, 1), 200)
            let year = params.get("year", as: Int.self)
            let album = decodedParam(request.uri, "album")
            let favorites = params.get("favorites", as: Bool.self)
            let mediaType = params.get("type", as: String.self)

            let result = await dataStore.query(
                year: year, album: album, favorites: favorites,
                mediaType: mediaType, page: page, pageSize: pageSize,
            )

            let assetsWithURLs = result.assets.map { asset in
                assetResponse(asset, expires: 14400)
            }

            return AssetListResponse(
                assets: assetsWithURLs,
                totalCount: result.totalCount,
                page: page,
                pageSize: pageSize,
            )
        }

        router.get("/api/assets/:uuid") { _, context -> Response in
            let uuid = try context.parameters.require("uuid")
            guard S3Paths.isValidUUID(uuid) else {
                return Response(status: .badRequest)
            }
            guard let asset = await dataStore.asset(uuid: uuid) else {
                return Response(status: .notFound)
            }

            let detail = assetResponse(asset, expires: 14400)
            let data = try JSONEncoder().encode(detail)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(data: data)),
            )
        }

        router.get("/api/thumb/:uuid") { _, context -> Response in
            let uuid = try context.parameters.require("uuid")
            guard S3Paths.isValidUUID(uuid) else {
                return Response(status: .badRequest)
            }
            do {
                let data = try await thumbnailProvider.thumbnail(uuid: uuid)
                return Response(
                    status: .ok,
                    headers: [
                        .contentType: "image/jpeg",
                        .cacheControl: "public, max-age=31536000, immutable",
                    ],
                    body: .init(byteBuffer: .init(data: data)),
                )
            } catch {
                return Response(status: .notFound)
            }
        }
    }

    private func assetResponse(_ asset: AssetView, expires: Int) -> AssetResponse {
        AssetResponse(
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
                .absoluteString,
        )
    }
}

/// Decode a query parameter, converting `+` to space.
/// URLSearchParams encodes spaces as `+` but Hummingbird only decodes `%XX`.
private func decodedParam(_ uri: URI, _ name: String) -> String? {
    uri.queryParameters.get(name, as: String.self)?
        .replacingOccurrences(of: "+", with: " ")
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
