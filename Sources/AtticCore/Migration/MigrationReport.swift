import Foundation

/// Aggregated outcome of a full migration run, surfaced to the CLI for
/// user-visible reporting.
public struct MigrationReport: Sendable {
    public var alreadyMigrated: Bool
    public var cloudMigrated: Int
    public var localFallback: Int
    public var multipleFoundCollisions: [String]
    public var rekeyCollisions: [String]
    public var errors: [String: String]
    public var unmapped: [String]
    public var metadataRewritten: Int
    public var metadataMissing: Int
    public var totalEntries: Int
    /// Number of orphaned `thumbnails/` keys deleted (or, in dry-run, the
    /// count that would be deleted). Zero when the cleanup phase did not run.
    public var thumbnailsDeleted: Int
    /// Total size in bytes of thumbnails deleted (or planned for deletion in
    /// dry-run). Zero when the cleanup phase did not run.
    public var thumbnailsBytes: Int64

    public init(
        alreadyMigrated: Bool = false,
        cloudMigrated: Int = 0,
        localFallback: Int = 0,
        multipleFoundCollisions: [String] = [],
        rekeyCollisions: [String] = [],
        errors: [String: String] = [:],
        unmapped: [String] = [],
        metadataRewritten: Int = 0,
        metadataMissing: Int = 0,
        totalEntries: Int = 0,
        thumbnailsDeleted: Int = 0,
        thumbnailsBytes: Int64 = 0,
    ) {
        self.alreadyMigrated = alreadyMigrated
        self.cloudMigrated = cloudMigrated
        self.localFallback = localFallback
        self.multipleFoundCollisions = multipleFoundCollisions
        self.rekeyCollisions = rekeyCollisions
        self.errors = errors
        self.unmapped = unmapped
        self.metadataRewritten = metadataRewritten
        self.metadataMissing = metadataMissing
        self.totalEntries = totalEntries
        self.thumbnailsDeleted = thumbnailsDeleted
        self.thumbnailsBytes = thumbnailsBytes
    }
}

/// Format a ``MigrationReport`` as a single JSON object. Stable schema for
/// agent / CI consumption: keys never disappear, counters always present
/// (zero when the category did not fire), arrays empty when no entries.
public func formatMigrationReportJSON(_ report: MigrationReport, dryRun: Bool) throws -> Data {
    var json: [String: Any] = [
        "alreadyMigrated": report.alreadyMigrated,
        "dryRun": dryRun,
        "totalEntries": report.totalEntries,
        "cloudMigrated": report.cloudMigrated,
        "localFallback": report.localFallback,
        "metadataRewritten": report.metadataRewritten,
        "metadataMissing": report.metadataMissing,
        "rekeyCollisions": report.rekeyCollisions,
        "multipleFoundCollisions": report.multipleFoundCollisions,
        "unmapped": report.unmapped,
        "thumbnailsDeleted": report.thumbnailsDeleted,
        "thumbnailsBytes": report.thumbnailsBytes,
    ]
    var errs: [[String: String]] = []
    for (uuid, message) in report.errors {
        errs.append(["uuid": uuid, "message": message])
    }
    json["errors"] = errs
    return try JSONSerialization.data(
        withJSONObject: json,
        options: [.prettyPrinted, .sortedKeys],
    )
}

/// Format a ``MigrationReport`` as a human-readable, multi-line string for
/// CLI display. Pure: no I/O — caller writes to stdout.
public func formatMigrationReport(_ report: MigrationReport, dryRun: Bool) -> String {
    if report.alreadyMigrated {
        return "Manifest is already v2.\n"
    }
    var out = "──────────────────────────────────────\n"
    out += "Migration report\(dryRun ? " (dry run)" : "")\n"
    out += "  Total entries          \(report.totalEntries)\n"
    out += "  Re-keyed to cloud id   \(report.cloudMigrated)\n"
    out += "  Local fallback         \(report.localFallback)\n"
    if !report.unmapped.isEmpty {
        out += "  Unmapped (deleted?)    \(report.unmapped.count)\n"
    }
    if !report.multipleFoundCollisions.isEmpty {
        out += "  Multiple-found        \(report.multipleFoundCollisions.count) (review manually)\n"
    }
    if !report.rekeyCollisions.isEmpty {
        out += "  Re-key collisions     \(report.rekeyCollisions.count)\n"
    }
    if !report.errors.isEmpty {
        out += "  Transient errors       \(report.errors.count) (re-run to retry)\n"
    }
    if !dryRun {
        out += "  Metadata JSONs rewritten  \(report.metadataRewritten)\n"
        if report.metadataMissing > 0 {
            out += "  Metadata JSONs missing    \(report.metadataMissing)\n"
        }
    }
    out += "\n"
    return out
}
