import Foundation

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
        isVideo: Bool, width: Int, height: Int, s3Key: String
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
    private var cachedFilterOptions: FilterOptions?

    public init() {}

    /// Load metadata for all manifest entries from S3.
    /// Calls `onProgress` with (loaded, total) counts.
    public func load(
        manifest: Manifest,
        s3: S3Providing,
        onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async {
        let entries = Array(manifest.entries.values)
        let total = entries.count
        if total == 0 { return }

        let loaded = LoadCounter()

        let maxConcurrency = 20

        await withTaskGroup(of: AssetView?.self) { group in
            for (index, entry) in entries.enumerated() {
                // Limit concurrency by waiting for a result before adding more
                if index >= maxConcurrency {
                    if let view = await group.next() ?? nil {
                        assets.append(view)
                    }
                }

                group.addTask {
                    do {
                        let key = try S3Paths.metadataKey(uuid: entry.uuid)
                        let data = try await s3.getObject(key: key)
                        let meta = try JSONDecoder().decode(AssetMetadata.self, from: data)
                        let count = await loaded.increment()
                        onProgress(count, total)
                        return Self.assetView(from: meta)
                    } catch {
                        let count = await loaded.increment()
                        onProgress(count, total)
                        return nil
                    }
                }
            }

            // Drain remaining tasks
            for await view in group {
                if let view { assets.append(view) }
            }
        }

        // Sort by date descending (newest first), nil dates last
        assets.sort { a, b in
            switch (a.dateCreated, b.dateCreated) {
            case let (dateA?, dateB?): return dateA > dateB
            case (nil, _): return false
            case (_, nil): return true
            }
        }

        rebuildIndexes()
    }

    /// Load from pre-built asset views (for testing).
    public func load(assets: [AssetView]) {
        self.assets = assets
        rebuildIndexes()
    }

    private func rebuildIndexes() {
        assetsByUUID = Dictionary(uniqueKeysWithValues: assets.map { ($0.uuid, $0) })
        cachedFilterOptions = buildFilterOptions()
    }

    /// Query assets with optional filters, paginated.
    public func query(
        year: Int? = nil,
        album: String? = nil,
        favorites: Bool? = nil,
        mediaType: String? = nil,
        page: Int = 1,
        pageSize: Int = 50
    ) -> AssetPage {
        var filtered = assets

        if let year {
            filtered = filtered.filter { $0.year == year }
        }
        if let album {
            filtered = filtered.filter { $0.albums.contains(album) }
        }
        if let favorites, favorites {
            filtered = filtered.filter { $0.isFavorite }
        }
        if let mediaType {
            switch mediaType {
            case "photo": filtered = filtered.filter { !$0.isVideo }
            case "video": filtered = filtered.filter { $0.isVideo }
            default: break
            }
        }

        let totalCount = filtered.count
        let startIndex = (page - 1) * pageSize
        let endIndex = min(startIndex + pageSize, totalCount)
        let pageAssets = startIndex < totalCount
            ? Array(filtered[startIndex..<endIndex])
            : []

        return AssetPage(
            assets: pageAssets,
            totalCount: totalCount
        )
    }

    /// Available filter options derived from loaded data.
    public func filterOptions() -> FilterOptions {
        cachedFilterOptions ?? FilterOptions(
            years: [], albums: [],
            totalAssets: 0, totalPhotos: 0, totalVideos: 0
        )
    }

    /// Find a single asset by UUID (O(1) dictionary lookup).
    public func asset(uuid: String) -> AssetView? {
        assetsByUUID[uuid]
    }

    // MARK: - Private

    private func buildFilterOptions() -> FilterOptions {
        var yearCounts: [Int: Int] = [:]
        var albumCounts: [String: Int] = [:]
        var photoCount = 0
        var videoCount = 0

        for asset in assets {
            if let year = asset.year {
                yearCounts[year, default: 0] += 1
            }
            for album in asset.albums {
                albumCounts[album, default: 0] += 1
            }
            if asset.isVideo { videoCount += 1 } else { photoCount += 1 }
        }

        return FilterOptions(
            years: yearCounts.map { YearCount(year: $0.key, count: $0.value) }
                .sorted { $0.year > $1.year },
            albums: albumCounts.map { AlbumCount(album: $0.key, count: $0.value) }
                .sorted { $0.count > $1.count },
            totalAssets: assets.count,
            totalPhotos: photoCount,
            totalVideos: videoCount
        )
    }

    private static let videoUTIs: Set<String> = [
        "public.mpeg-4", "com.apple.quicktime-movie",
        "com.apple.m4v-video", "public.avi",
    ]

    private nonisolated(unsafe) static let isoFormatter = ISO8601DateFormatter()

    private static func assetView(from meta: AssetMetadata) -> AssetView {
        let year: Int?
        if let dateStr = meta.dateCreated,
           let date = isoFormatter.date(from: dateStr) {
            year = Calendar.current.component(.year, from: date)
        } else {
            year = nil
        }

        let isVideo = meta.type.map { videoUTIs.contains($0) } ?? false

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
            s3Key: meta.s3Key
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
