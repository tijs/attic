import Foundation

/// Result of a rebuild-manifest run.
public struct RebuildManifestReport: Sendable {
    public var recovered: Int = 0
    public var skipped: Int = 0
    public var errors: [(key: String, message: String)] = []
}

/// Rebuild manifest from S3 metadata JSON files.
///
/// Scans `metadata/assets/` in S3, parses each JSON file, and reconstructs
/// manifest entries. Used as a disaster recovery mechanism when the manifest
/// is lost or corrupted.
public func runRebuildManifest(
    s3: any S3Providing,
    manifestStore: any ManifestStoring,
) async throws -> (Manifest, RebuildManifestReport) {
    let objects = try await s3.listObjects(prefix: "metadata/assets/")
    var manifest = Manifest()
    var report = RebuildManifestReport()

    for obj in objects {
        guard obj.key.hasSuffix(".json") else {
            report.skipped += 1
            continue
        }

        do {
            let data = try await s3.getObject(key: obj.key)
            let parsed = try JSONDecoder().decode(MetadataForRebuild.self, from: data)

            guard S3Paths.isValidUUID(parsed.uuid),
                  S3Paths.isValidS3Key(parsed.s3Key),
                  isValidChecksum(parsed.checksum)
            else {
                report.errors.append((key: obj.key, message: "Validation failed"))
                continue
            }

            manifest.markBackedUp(
                uuid: parsed.uuid,
                s3Key: parsed.s3Key,
                checksum: parsed.checksum,
                backedUpAt: parsed.backedUpAt ?? isoFormatter.string(from: Date()),
            )
            report.recovered += 1
        } catch {
            report.errors.append((key: obj.key, message: String(describing: error)))
        }
    }

    try await manifestStore.save(manifest)
    return (manifest, report)
}

// MARK: - Internals

/// Minimal struct for parsing metadata JSON during rebuild.
private struct MetadataForRebuild: Decodable {
    let uuid: String
    let s3Key: String
    let checksum: String
    let backedUpAt: String?
}

nonisolated(unsafe) private let checksumValidation = /^sha256:[a-f0-9]+$/

private func isValidChecksum(_ value: String) -> Bool {
    value.wholeMatch(of: checksumValidation) != nil
}
