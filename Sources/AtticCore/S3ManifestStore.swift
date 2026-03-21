import Foundation

/// Manifest store backed by S3. This is the primary store.
public struct S3ManifestStore: ManifestStoring {
    private let s3: any S3Providing
    private let key: String

    public init(s3: any S3Providing, key: String = manifestS3Key) {
        self.s3 = s3
        self.key = key
    }

    public func load() async throws -> Manifest {
        do {
            let data = try await s3.getObject(key: key)
            return try Manifest.parse(from: data)
        } catch {
            if isNotFoundError(error) {
                return Manifest()
            }
            throw error
        }
    }

    public func save(_ manifest: Manifest) async throws {
        let data = try manifest.encoded()
        try await s3.putObject(key: key, body: data, contentType: "application/json")
    }
}

/// Load manifest from S3, migrating from local file if needed.
///
/// TODO: Remove this migration path once all users have upgraded from the
/// Deno CLI (v0.2.x) to the Swift CLI. At that point everyone's manifest
/// will already be on S3 and the local-file fallback is dead code.
///
/// Migration flow (one-time):
/// 1. If S3 has a manifest with entries, use it.
/// 2. If S3 is empty, check for a local manifest at ~/.attic/manifest.json.
/// 3. If local exists, upload it to S3 and return it.
/// 4. If neither exists, return empty manifest.
public func loadManifestWithMigration(
    s3Store: ManifestStoring,
    localDirectory: URL? = nil
) async throws -> Manifest {
    let s3Manifest = try await s3Store.load()

    if !s3Manifest.entries.isEmpty {
        return s3Manifest
    }

    // Check for local manifest to migrate
    let dir = localDirectory
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".attic")
    let localPath = dir.appendingPathComponent("manifest.json")

    guard FileManager.default.fileExists(atPath: localPath.path) else {
        return s3Manifest
    }

    do {
        let data = try Data(contentsOf: localPath)
        let localManifest = try Manifest.parse(from: data)

        if !localManifest.entries.isEmpty {
            debugPrint("  Migrating local manifest (\(localManifest.entries.count) entries) to S3...")
            try await s3Store.save(localManifest)
            debugPrint("  Migration complete.\n")
            return localManifest
        }
    } catch {
        // No local manifest or unreadable — that's fine
    }

    return s3Manifest
}

private func isNotFoundError(_ error: Error) -> Bool {
    let description = String(describing: error)
    return description.contains("NotFound") || description.contains("NoSuchKey")
        || description.contains("notFound")
}
