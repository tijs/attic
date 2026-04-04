import Foundation
import LadderKit

// MARK: - Dashboard Data Models

public struct DashboardData: Sendable {
    public let version: String
    public let library: LibraryStats
    public let backup: BackupStats?
    public let s3: S3Info?
    public let types: [(uti: String, percentage: Double)]

    public init(
        version: String,
        library: LibraryStats,
        backup: BackupStats?,
        s3: S3Info?,
        types: [(uti: String, percentage: Double)],
    ) {
        self.version = version
        self.library = library
        self.backup = backup
        self.s3 = s3
        self.types = types
    }
}

public struct LibraryStats: Sendable, Equatable {
    public let photos: Int
    public let videos: Int
    public let favorites: Int
    public let edited: Int

    public var total: Int {
        photos + videos
    }

    public init(photos: Int, videos: Int, favorites: Int, edited: Int) {
        self.photos = photos
        self.videos = videos
        self.favorites = favorites
        self.edited = edited
    }
}

public struct BackupStats: Sendable, Equatable {
    public let backedUp: Int
    public let backedUpBytes: Int
    public let pending: Int
    public let total: Int

    public var percentage: Double {
        total == 0 ? 100.0 : Double(backedUp) / Double(total) * 100
    }

    public init(backedUp: Int, backedUpBytes: Int, pending: Int, total: Int) {
        self.backedUp = backedUp
        self.backedUpBytes = backedUpBytes
        self.pending = pending
        self.total = total
    }
}

public struct S3Info: Sendable, Equatable {
    public let bucket: String
    public let manifestEntries: Int
    public let lastBackup: String?

    public init(bucket: String, manifestEntries: Int, lastBackup: String?) {
        self.bucket = bucket
        self.manifestEntries = manifestEntries
        self.lastBackup = lastBackup
    }
}

// MARK: - Stats Computation

public enum StatusStats {
    public static func computeLibraryStats(_ assets: [AssetInfo]) -> LibraryStats {
        var photos = 0, videos = 0, favorites = 0, edited = 0
        for asset in assets {
            if asset.kind == .photo { photos += 1 } else { videos += 1 }
            if asset.isFavorite { favorites += 1 }
            if asset.hasEdit { edited += 1 }
        }
        return LibraryStats(photos: photos, videos: videos, favorites: favorites, edited: edited)
    }

    public static func computeUTIBreakdown(
        _ assets: [AssetInfo],
        topN: Int = 5,
    ) -> [(uti: String, percentage: Double)] {
        guard !assets.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for asset in assets {
            let uti = asset.uniformTypeIdentifier ?? "unknown"
            let display = uti.hasPrefix("public.") ? String(uti.dropFirst(7)).uppercased() : uti.uppercased()
            counts[display, default: 0] += 1
        }
        let sorted = counts.sorted { $0.value > $1.value }
        let total = Double(assets.count)
        var result: [(uti: String, percentage: Double)] = []
        var shown = 0.0

        for (index, entry) in sorted.enumerated() {
            let pct = Double(entry.value) / total * 100
            if index < topN {
                result.append((uti: entry.key, percentage: pct))
                shown += pct
            } else {
                break
            }
        }

        let otherPct = 100.0 - shown
        if otherPct > 0.5 {
            result.append((uti: "Other", percentage: otherPct))
        }

        return result
    }

    public static func computeBackupStats(assets: [AssetInfo], manifest: Manifest) -> BackupStats {
        var backedUp = 0, backedUpBytes = 0
        for asset in assets {
            if manifest.isBackedUp(asset.uuid) {
                backedUp += 1
                backedUpBytes += manifest.entries[asset.uuid]?.size ?? 0
            }
        }
        return BackupStats(
            backedUp: backedUp,
            backedUpBytes: backedUpBytes,
            pending: assets.count - backedUp,
            total: assets.count,
        )
    }

    public static func computeS3Info(bucket: String, manifest: Manifest) -> S3Info {
        let lastBackup = manifest.entries.values
            .map(\.backedUpAt)
            .max()
        let displayDate: String? = lastBackup.flatMap { iso in
            let trimmed = String(iso.prefix(10))
            return trimmed.count == 10 ? trimmed : iso
        }
        return S3Info(
            bucket: bucket,
            manifestEntries: manifest.entries.count,
            lastBackup: displayDate,
        )
    }
}
