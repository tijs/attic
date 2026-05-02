@testable import AtticCore
import Foundation
import Testing

@Suite("formatMigrationReport")
struct MigrateReportFormatterTests {
    @Test func alreadyMigratedShortCircuits() {
        let report = MigrationReport(alreadyMigrated: true, totalEntries: 100)
        let out = formatMigrationReport(report, dryRun: false)
        #expect(out.contains("already v2"))
        #expect(!out.contains("Re-keyed to cloud id"))
    }

    @Test func includesCounts() {
        let report = MigrationReport(
            cloudMigrated: 10,
            localFallback: 2,
            metadataRewritten: 8,
            metadataMissing: 0,
            totalEntries: 12,
        )
        let out = formatMigrationReport(report, dryRun: false)
        #expect(out.contains("Total entries          12"))
        #expect(out.contains("Re-keyed to cloud id   10"))
        #expect(out.contains("Local fallback         2"))
        #expect(out.contains("Metadata JSONs rewritten  8"))
        #expect(!out.contains("Metadata JSONs missing"))
    }

    @Test func dryRunOmitsRewriteCounts() {
        let report = MigrationReport(
            cloudMigrated: 5,
            metadataRewritten: 0,
            totalEntries: 5,
        )
        let out = formatMigrationReport(report, dryRun: true)
        #expect(out.contains("(dry run)"))
        #expect(!out.contains("Metadata JSONs rewritten"))
    }

    @Test func surfacesRekeyAndMultipleFoundOnlyWhenPresent() {
        let report = MigrationReport(
            cloudMigrated: 1,
            multipleFoundCollisions: ["A"],
            rekeyCollisions: ["B"],
            errors: ["C": "boom"],
            unmapped: ["D"],
            totalEntries: 5,
        )
        let out = formatMigrationReport(report, dryRun: false)
        #expect(out.contains("Multiple-found"))
        #expect(out.contains("Re-key collisions"))
        #expect(out.contains("Transient errors"))
        #expect(out.contains("Unmapped"))
    }

    @Test func jsonFormatStableSchema() throws {
        let report = MigrationReport(
            alreadyMigrated: false,
            cloudMigrated: 3,
            localFallback: 1,
            multipleFoundCollisions: ["X"],
            rekeyCollisions: ["Y"],
            errors: ["Z": "boom"],
            unmapped: ["W"],
            metadataRewritten: 2,
            metadataMissing: 1,
            totalEntries: 4,
        )
        let data = try formatMigrationReportJSON(report, dryRun: false)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["alreadyMigrated"] as? Bool == false)
        #expect(json["dryRun"] as? Bool == false)
        #expect(json["totalEntries"] as? Int == 4)
        #expect(json["cloudMigrated"] as? Int == 3)
        #expect(json["localFallback"] as? Int == 1)
        #expect(json["metadataRewritten"] as? Int == 2)
        #expect(json["metadataMissing"] as? Int == 1)
        #expect((json["rekeyCollisions"] as? [String]) == ["Y"])
        #expect((json["multipleFoundCollisions"] as? [String]) == ["X"])
        #expect((json["unmapped"] as? [String]) == ["W"])
        let errors = try #require(json["errors"] as? [[String: String]])
        #expect(errors.count == 1)
        #expect(errors[0]["uuid"] == "Z")
        #expect(errors[0]["message"] == "boom")
    }

    @Test func jsonFormatIncludesEmptyArraysWhenNoEntries() throws {
        let report = MigrationReport(
            alreadyMigrated: true,
            totalEntries: 100,
        )
        let data = try formatMigrationReportJSON(report, dryRun: false)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Arrays must always be present (stable schema for agents).
        #expect((json["rekeyCollisions"] as? [String]) == [])
        #expect((json["multipleFoundCollisions"] as? [String]) == [])
        #expect((json["unmapped"] as? [String]) == [])
        #expect((json["errors"] as? [[String: String]])?.isEmpty == true)
        #expect(json["alreadyMigrated"] as? Bool == true)
    }

    @Test func includesMetadataMissingLineWhenNonZero() {
        let report = MigrationReport(
            cloudMigrated: 3,
            metadataRewritten: 2,
            metadataMissing: 1,
            totalEntries: 3,
        )
        let out = formatMigrationReport(report, dryRun: false)
        #expect(out.contains("Metadata JSONs missing    1"))
    }
}
