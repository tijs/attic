import Foundation
import LadderKit

// MARK: - Dashboard Data Models

public struct TypeBreakdown: Sendable, Equatable {
    public let uti: String
    public let percentage: Double

    public init(uti: String, percentage: Double) {
        self.uti = uti
        self.percentage = percentage
    }
}

public struct DashboardData: Sendable {
    public let version: String
    public let library: LibraryStats
    public let backup: BackupStats?
    public let s3: S3Info?
    public let types: [TypeBreakdown]
    public let retry: RetryInfo?

    public init(
        version: String,
        library: LibraryStats,
        backup: BackupStats?,
        s3: S3Info?,
        types: [TypeBreakdown],
        retry: RetryInfo? = nil,
    ) {
        self.version = version
        self.library = library
        self.backup = backup
        self.s3 = s3
        self.types = types
        self.retry = retry
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
    /// Pending assets whose originals are cached locally — these run in the
    /// fast lane at full concurrency. Nil when local availability couldn't
    /// be determined (Photos.sqlite unreadable).
    public let pendingLocal: Int?

    public var percentage: Double {
        total == 0 ? 100.0 : Double(backedUp) / Double(total) * 100
    }

    /// Pending assets that aren't cached locally and must be downloaded from
    /// iCloud first — these run in the throttled lane.
    public var pendingCloud: Int? {
        pendingLocal.map { pending - $0 }
    }

    public init(
        backedUp: Int,
        backedUpBytes: Int,
        pending: Int,
        total: Int,
        pendingLocal: Int? = nil,
    ) {
        self.backedUp = backedUp
        self.backedUpBytes = backedUpBytes
        self.pending = pending
        self.total = total
        self.pendingLocal = pendingLocal
    }
}

/// Retry-queue summary for the status dashboard.
public struct RetryInfo: Sendable, Equatable {
    public let count: Int
    public let maxAttempts: Int
    public let oldestFirstFailedAt: String?

    public init(count: Int, maxAttempts: Int, oldestFirstFailedAt: String?) {
        self.count = count
        self.maxAttempts = maxAttempts
        self.oldestFirstFailedAt = oldestFirstFailedAt
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
    ) -> [TypeBreakdown] {
        guard !assets.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for asset in assets {
            let uti = asset.uniformTypeIdentifier ?? "unknown"
            let display = uti.hasPrefix("public.") ? String(uti.dropFirst(7)).uppercased() : uti.uppercased()
            counts[display, default: 0] += 1
        }
        let sorted = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let total = Double(assets.count)
        var result: [TypeBreakdown] = []
        var shown = 0.0

        for (index, entry) in sorted.enumerated() {
            let pct = Double(entry.value) / total * 100
            if index < topN {
                result.append(TypeBreakdown(uti: entry.key, percentage: pct))
                shown += pct
            } else {
                break
            }
        }

        let otherPct = 100.0 - shown
        if otherPct > 0.5 {
            result.append(TypeBreakdown(uti: "Other", percentage: otherPct))
        }

        return result
    }

    public static func computeBackupStats(
        assets: [AssetInfo],
        manifest: Manifest,
        localAvailability: (any LocalAvailabilityProviding)? = nil,
    ) -> BackupStats {
        var backedUp = 0, backedUpBytes = 0, pendingLocal = 0
        for asset in assets {
            if let entry = manifest.entries[asset.uuid] {
                backedUp += 1
                backedUpBytes += entry.size ?? 0
            } else if localAvailability?.isLocallyAvailable(uuid: asset.uuid) == true {
                pendingLocal += 1
            }
        }
        return BackupStats(
            backedUp: backedUp,
            backedUpBytes: backedUpBytes,
            pending: assets.count - backedUp,
            total: assets.count,
            pendingLocal: localAvailability == nil ? nil : pendingLocal,
        )
    }

    public static func computeRetryInfo(_ queue: RetryQueue?) -> RetryInfo? {
        guard let queue, !queue.entries.isEmpty else { return nil }
        let maxAttempts = queue.entries.map(\.attempts).max() ?? 0
        let oldest = queue.entries
            .map(\.firstFailedAt)
            .filter { !$0.isEmpty }
            .min()
        return RetryInfo(
            count: queue.entries.count,
            maxAttempts: maxAttempts,
            oldestFirstFailedAt: oldest,
        )
    }

    public static func computeS3Info(bucket: String, manifest: Manifest) -> S3Info {
        let lastBackup = manifest.entries.values
            .max(by: { $0.backedUpAt < $1.backedUpAt })
            .map(\.backedUpAt)
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
