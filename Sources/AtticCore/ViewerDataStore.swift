import Foundation
import UniformTypeIdentifiers

/// Lightweight view of an asset for the viewer UI.
public struct AssetView: Codable, Sendable {
    public var uuid: String
    public var filename: String
    public var dateCreated: String?
    public var year: Int?
    public var albums: [String]
    public var isFavorite: Bool
    public var isVideo: Bool
    public var width: Int
    public var height: Int
    public var s3Key: String

    public init(
        uuid: String, filename: String, dateCreated: String?,
        year: Int?, albums: [String], isFavorite: Bool,
        isVideo: Bool, width: Int, height: Int, s3Key: String,
    ) {
        self.uuid = uuid
        self.filename = filename
        self.dateCreated = dateCreated
        self.year = year
        self.albums = albums
        self.isFavorite = isFavorite
        self.isVideo = isVideo
        self.width = width
        self.height = height
        self.s3Key = s3Key
    }
}

/// Available filter values for the viewer UI.
public struct FilterOptions: Codable, Sendable {
    public var years: [YearCount]
    public var albums: [AlbumCount]
    public var totalAssets: Int
    public var totalPhotos: Int
    public var totalVideos: Int
    public var isLoading: Bool
    public var loaded: Int
    public var totalInLibrary: Int
}

/// Year with asset count.
public struct YearCount: Codable, Sendable {
    public var year: Int
    public var count: Int
}

/// Album title with asset count.
public struct AlbumCount: Codable, Sendable {
    public var album: String
    public var count: Int
}

/// Result from a filtered query.
public struct AssetPage: Sendable {
    public var assets: [AssetView]
    public var totalCount: Int
}

/// Loads all backed-up asset metadata from S3 into memory for fast filtering.
public actor ViewerDataStore {
    private var assets: [AssetView] = []
    private var assetsByUUID: [String: AssetView] = [:]
    private var _isLoading = false
    private var _loadedCount = 0
    private var _expectedTotal = 0

    public init() {}

    // MARK: - Loading

    /// Load metadata for all manifest entries from S3.
    /// Assets become queryable as they arrive. Sorts after completion.
    public func load(
        manifest: Manifest,
        s3: S3Providing,
        onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
    ) async {
        let entries = Array(manifest.entries.values)
        _expectedTotal = entries.count
        _loadedCount = 0
        _isLoading = true

        if entries.isEmpty {
            _isLoading = false
            return
        }

        let loaded = LoadCounter()
        let maxConcurrency = 20

        await withTaskGroup(of: AssetView?.self) { group in
            for (index, entry) in entries.enumerated() {
                if index >= maxConcurrency {
                    if let view = await group.next() ?? nil {
                        appendAsset(view)
                    }
                }

                group.addTask {
                    do {
                        let key = try S3Paths.metadataKey(uuid: entry.uuid)
                        let data = try await s3.getObject(key: key)
                        let meta = try JSONDecoder().decode(AssetMetadata.self, from: data)
                        let count = await loaded.increment()
                        onProgress(count, entries.count)
                        return Self.assetView(from: meta)
                    } catch {
                        let count = await loaded.increment()
                        onProgress(count, entries.count)
                        return nil
                    }
                }
            }

            for await view in group {
                if let view { appendAsset(view) }
            }
        }

        // Sort by date descending (newest first), nil dates last
        assets.sort { a, b in
            switch (a.dateCreated, b.dateCreated) {
            case let (dateA?, dateB?): dateA > dateB
            case (nil, _): false
            case (_, nil): true
            }
        }

        _isLoading = false
    }

    /// Load from pre-built asset views (for testing).
    public func load(assets: [AssetView]) {
        self.assets = assets
        assetsByUUID = Dictionary(uniqueKeysWithValues: assets.map { ($0.uuid, $0) })
    }

    private func appendAsset(_ view: AssetView) {
        assets.append(view)
        assetsByUUID[view.uuid] = view
        _loadedCount += 1
    }

    // MARK: - Queries

    /// Query assets with optional filters, paginated.
    public func query(
        year: Int? = nil,
        album: String? = nil,
        favorites: Bool? = nil,
        mediaType: String? = nil,
        page: Int = 1,
        pageSize: Int = 50,
    ) -> AssetPage {
        let filtered = applyFilters(
            year: year, album: album, favorites: favorites, mediaType: mediaType,
        )

        let totalCount = filtered.count
        let startIndex = (page - 1) * pageSize
        let endIndex = min(startIndex + pageSize, totalCount)
        let pageAssets = startIndex < totalCount
            ? Array(filtered[startIndex ..< endIndex])
            : []

        return AssetPage(assets: pageAssets, totalCount: totalCount)
    }

    /// Cascading filter options: each dimension is filtered by the OTHER active
    /// filters, so counts and available options update as filters are applied.
    /// Single-pass implementation — one loop over assets, three accumulators.
    public func filterOptions(
        year: Int? = nil,
        album: String? = nil,
        favorites: Bool? = nil,
        mediaType: String? = nil,
    ) -> FilterOptions {
        var yearCounts: [Int: Int] = [:]
        var albumCounts: [String: Int] = [:]
        var photoCount = 0
        var videoCount = 0

        for asset in assets {
            let matchesYear = year == nil || asset.year == year
            let matchesAlbum = album == nil || asset.albums.contains(album!)
            let matchesFav = favorites != true || asset.isFavorite
            let matchesType: Bool = switch mediaType {
            case "photo": !asset.isVideo
            case "video": asset.isVideo
            default: true
            }

            // Year counts: apply all filters except year
            if matchesAlbum, matchesFav, matchesType {
                if let y = asset.year { yearCounts[y, default: 0] += 1 }
            }
            // Album counts: apply all filters except album
            if matchesYear, matchesFav, matchesType {
                for a in asset.albums {
                    albumCounts[a, default: 0] += 1
                }
            }
            // Totals: all filters applied
            if matchesYear, matchesAlbum, matchesFav, matchesType {
                if asset.isVideo { videoCount += 1 } else { photoCount += 1 }
            }
        }

        return FilterOptions(
            years: yearCounts.map { YearCount(year: $0.key, count: $0.value) }
                .sorted { $0.year > $1.year },
            albums: albumCounts.map { AlbumCount(album: $0.key, count: $0.value) }
                .sorted { $0.count > $1.count },
            totalAssets: photoCount + videoCount,
            totalPhotos: photoCount,
            totalVideos: videoCount,
            isLoading: _isLoading,
            loaded: _loadedCount,
            totalInLibrary: _isLoading ? _expectedTotal : assets.count,
        )
    }

    /// Find a single asset by UUID (O(1) dictionary lookup).
    public func asset(uuid: String) -> AssetView? {
        assetsByUUID[uuid]
    }

    // MARK: - Private

    private func applyFilters(
        year: Int?, album: String?, favorites: Bool?, mediaType: String?,
    ) -> [AssetView] {
        var filtered = assets
        if let year {
            filtered = filtered.filter { $0.year == year }
        }
        if let album {
            filtered = filtered.filter { $0.albums.contains(album) }
        }
        if let favorites, favorites {
            filtered = filtered.filter(\.isFavorite)
        }
        if let mediaType {
            switch mediaType {
            case "photo": filtered = filtered.filter { !$0.isVideo }
            case "video": filtered = filtered.filter(\.isVideo)
            default: break
            }
        }
        return filtered
    }

    private static func isVideoUTI(_ uti: String) -> Bool {
        guard let utType = UTType(uti) else { return false }
        return utType.conforms(to: .movie)
    }

    private static func assetView(from meta: AssetMetadata) -> AssetView {
        let year: Int? = if let dateStr = meta.dateCreated,
                            let date = try? Date.ISO8601FormatStyle().parse(dateStr)
        {
            Calendar.current.component(.year, from: date)
        } else {
            nil
        }

        let isVideo = meta.type.map { isVideoUTI($0) } ?? false

        return AssetView(
            uuid: meta.uuid,
            filename: meta.originalFilename,
            dateCreated: meta.dateCreated,
            year: year,
            albums: meta.albums.map(\.title),
            isFavorite: meta.favorite,
            isVideo: isVideo,
            width: meta.width,
            height: meta.height,
            s3Key: meta.s3Key,
        )
    }
}

/// Thread-safe counter for tracking concurrent progress.
private actor LoadCounter {
    private var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}
