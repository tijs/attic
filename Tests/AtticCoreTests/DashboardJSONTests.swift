@testable import AtticCore
import Foundation
import Testing

struct DashboardJSONTests {
    @Test func fullDashboardRoundTrips() throws {
        let data = DashboardData(
            version: "1.2.3",
            library: LibraryStats(photos: 100, videos: 20, favorites: 5, edited: 3),
            backup: BackupStats(
                backedUp: 90,
                backedUpBytes: 4096,
                pending: 30,
                total: 120,
                pendingLocal: 10,
            ),
            s3: S3Info(
                bucket: "my-bucket",
                manifestEntries: 90,
                lastBackup: "2026-08-20",
                lastBackupAt: "2026-08-20T21:17:45Z",
            ),
            types: [TypeBreakdown(uti: "public.heic", percentage: 80.5)],
            retry: RetryInfo(count: 2, maxAttempts: 5, oldestFirstFailedAt: "2026-08-19T03:30:00Z"),
        )

        let parsed = try #require(
            try JSONSerialization.jsonObject(with: formatDashboardJSON(data)) as? [String: Any],
        )

        #expect(parsed["version"] as? String == "1.2.3")
        let library = try #require(parsed["library"] as? [String: Any])
        #expect(library["photos"] as? Int == 100)
        #expect(library["total"] as? Int == 120)

        let backup = try #require(parsed["backup"] as? [String: Any])
        #expect(backup["backedUp"] as? Int == 90)
        #expect(backup["pending"] as? Int == 30)
        #expect(backup["pendingLocal"] as? Int == 10)
        #expect(backup["pendingCloud"] as? Int == 20)
        #expect(backup["percentage"] as? Double == 75.0)

        let s3 = try #require(parsed["s3"] as? [String: Any])
        #expect(s3["bucket"] as? String == "my-bucket")
        #expect(s3["manifestEntries"] as? Int == 90)
        #expect(s3["lastBackupAt"] as? String == "2026-08-20T21:17:45Z")

        let retry = try #require(parsed["retry"] as? [String: Any])
        #expect(retry["count"] as? Int == 2)
        #expect(retry["oldestFirstFailedAt"] as? String == "2026-08-19T03:30:00Z")

        let types = try #require(parsed["types"] as? [[String: Any]])
        #expect(types.first?["uti"] as? String == "public.heic")
    }

    @Test func unconfiguredDashboardOmitsOptionalSections() throws {
        let data = DashboardData(
            version: "1.2.3",
            library: LibraryStats(photos: 1, videos: 0, favorites: 0, edited: 0),
            backup: nil,
            s3: nil,
            types: [],
        )

        let parsed = try #require(
            try JSONSerialization.jsonObject(with: formatDashboardJSON(data)) as? [String: Any],
        )

        #expect(parsed["backup"] == nil)
        #expect(parsed["s3"] == nil)
        #expect(parsed["retry"] == nil)
        #expect(parsed["library"] != nil)
        #expect((parsed["types"] as? [Any])?.isEmpty == true)
    }

    @Test func unknownLocalAvailabilityOmitsLaneFields() throws {
        let data = DashboardData(
            version: "1.2.3",
            library: LibraryStats(photos: 1, videos: 0, favorites: 0, edited: 0),
            backup: BackupStats(backedUp: 1, backedUpBytes: 10, pending: 0, total: 1, pendingLocal: nil),
            s3: nil,
            types: [],
        )

        let backup = try #require(
            try (JSONSerialization.jsonObject(with: formatDashboardJSON(data)) as? [String: Any])?["backup"]
                as? [String: Any],
        )

        #expect(backup["pendingLocal"] == nil)
        #expect(backup["pendingCloud"] == nil)
    }
}
