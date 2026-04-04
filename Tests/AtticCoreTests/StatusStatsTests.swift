@testable import AtticCore
import LadderKit
import Testing

struct StatusStatsTests {
    // MARK: - Test Helpers

    private func makeAsset(
        uuid: String = "test-uuid",
        kind: AssetKind = .photo,
        uti: String? = "public.heic",
        isFavorite: Bool = false,
        hasEdit: Bool = false,
    ) -> AssetInfo {
        AssetInfo(
            identifier: "\(uuid)/L0/001",
            creationDate: nil,
            kind: kind,
            pixelWidth: 100,
            pixelHeight: 100,
            latitude: nil,
            longitude: nil,
            isFavorite: isFavorite,
            originalFilename: "IMG.HEIC",
            uniformTypeIdentifier: uti,
            hasEdit: hasEdit,
        )
    }

    // MARK: - Library Stats

    @Test func libraryStatsCountsPhotosAndVideos() {
        let assets = [
            makeAsset(uuid: "p1", kind: .photo),
            makeAsset(uuid: "p2", kind: .photo),
            makeAsset(uuid: "v1", kind: .video),
        ]
        let stats = StatusStats.computeLibraryStats(assets)
        #expect(stats.photos == 2)
        #expect(stats.videos == 1)
        #expect(stats.total == 3)
    }

    @Test func libraryStatsCountsFavoritesAndEdited() {
        let assets = [
            makeAsset(uuid: "1", isFavorite: true, hasEdit: true),
            makeAsset(uuid: "2", isFavorite: true),
            makeAsset(uuid: "3", hasEdit: true),
            makeAsset(uuid: "4"),
        ]
        let stats = StatusStats.computeLibraryStats(assets)
        #expect(stats.favorites == 2)
        #expect(stats.edited == 2)
    }

    @Test func libraryStatsEmptyLibrary() {
        let stats = StatusStats.computeLibraryStats([])
        #expect(stats == LibraryStats(photos: 0, videos: 0, favorites: 0, edited: 0))
    }

    // MARK: - UTI Breakdown

    @Test func utiBreakdownTopTypes() {
        let assets = [
            makeAsset(uuid: "1", uti: "public.heic"),
            makeAsset(uuid: "2", uti: "public.heic"),
            makeAsset(uuid: "3", uti: "public.heic"),
            makeAsset(uuid: "4", uti: "public.jpeg"),
            makeAsset(uuid: "5", uti: "public.png"),
        ]
        let breakdown = StatusStats.computeUTIBreakdown(assets)
        #expect(breakdown[0].uti == "HEIC")
        #expect(breakdown[0].percentage == 60.0)
        #expect(breakdown[1].uti == "JPEG")
        #expect(breakdown[1].percentage == 20.0)
        #expect(breakdown[2].uti == "PNG")
        #expect(breakdown[2].percentage == 20.0)
    }

    @Test func utiBreakdownGroupsOther() {
        // 6 types: top 5 shown, rest grouped as "Other"
        var assets: [AssetInfo] = []
        let types = ["public.heic", "public.jpeg", "public.png", "public.mov", "public.mp4", "public.tiff"]
        for (i, uti) in types.enumerated() {
            for j in 0 ..< (10 - i) {
                assets.append(makeAsset(uuid: "\(uti)-\(j)", uti: uti))
            }
        }
        let breakdown = StatusStats.computeUTIBreakdown(assets, topN: 5)
        #expect(breakdown.count == 6)
        #expect(breakdown.last?.uti == "Other")
    }

    @Test func utiBreakdownEmptyAssets() {
        let breakdown = StatusStats.computeUTIBreakdown([])
        #expect(breakdown.isEmpty)
    }

    @Test func utiBreakdownStripsPublicPrefix() {
        let assets = [makeAsset(uuid: "1", uti: "public.heif")]
        let breakdown = StatusStats.computeUTIBreakdown(assets)
        #expect(breakdown[0].uti == "HEIF")
    }

    @Test func utiBreakdownHandlesUnknown() {
        let assets = [makeAsset(uuid: "1", uti: nil)]
        let breakdown = StatusStats.computeUTIBreakdown(assets)
        #expect(breakdown[0].uti == "UNKNOWN")
    }

    // MARK: - Backup Stats

    @Test func backupStatsEmptyManifest() {
        let assets = [makeAsset(uuid: "1"), makeAsset(uuid: "2")]
        let manifest = Manifest(entries: [:])
        let stats = StatusStats.computeBackupStats(assets: assets, manifest: manifest)
        #expect(stats.backedUp == 0)
        #expect(stats.pending == 2)
        #expect(stats.percentage == 0.0)
    }

    @Test func backupStatsPartialBackup() {
        let assets = [makeAsset(uuid: "a"), makeAsset(uuid: "b"), makeAsset(uuid: "c")]
        let manifest = Manifest(entries: [
            "a": ManifestEntry(
                uuid: "a",
                s3Key: "originals/a.heic",
                checksum: "abc",
                backedUpAt: "2026-01-01",
                size: 1024,
            ),
        ])
        let stats = StatusStats.computeBackupStats(assets: assets, manifest: manifest)
        #expect(stats.backedUp == 1)
        #expect(stats.backedUpBytes == 1024)
        #expect(stats.pending == 2)
        #expect(stats.total == 3)
    }

    @Test func backupStatsFullBackup() {
        let assets = [makeAsset(uuid: "x")]
        let manifest = Manifest(entries: [
            "x": ManifestEntry(
                uuid: "x",
                s3Key: "originals/x.heic",
                checksum: "abc",
                backedUpAt: "2026-01-01",
                size: 2048,
            ),
        ])
        let stats = StatusStats.computeBackupStats(assets: assets, manifest: manifest)
        #expect(stats.backedUp == 1)
        #expect(stats.pending == 0)
        #expect(stats.percentage == 100.0)
    }

    @Test func backupStatsEmptyLibrary() {
        let stats = StatusStats.computeBackupStats(assets: [], manifest: Manifest())
        #expect(stats.percentage == 100.0)
        #expect(stats.total == 0)
    }

    // MARK: - S3 Info

    @Test func s3InfoDeriesLastBackup() {
        let manifest = Manifest(entries: [
            "a": ManifestEntry(uuid: "a", s3Key: "k", checksum: "c", backedUpAt: "2026-01-15T10:00:00Z"),
            "b": ManifestEntry(uuid: "b", s3Key: "k", checksum: "c", backedUpAt: "2026-04-03T14:22:00Z"),
            "c": ManifestEntry(uuid: "c", s3Key: "k", checksum: "c", backedUpAt: "2026-02-20T08:00:00Z"),
        ])
        let info = StatusStats.computeS3Info(bucket: "my-bucket", manifest: manifest)
        #expect(info.bucket == "my-bucket")
        #expect(info.manifestEntries == 3)
        #expect(info.lastBackup == "2026-04-03")
    }

    @Test func s3InfoEmptyManifest() {
        let info = StatusStats.computeS3Info(bucket: "b", manifest: Manifest())
        #expect(info.manifestEntries == 0)
        #expect(info.lastBackup == nil)
    }

    // MARK: - BackupStats percentage

    @Test func backupPercentageAt50() {
        let stats = BackupStats(backedUp: 5, backedUpBytes: 0, pending: 5, total: 10)
        #expect(stats.percentage == 50.0)
    }
}
