import Foundation
import LadderKit

/// Outcome of running a v1 → v2 cloud-identity migration over a manifest,
/// retry queue, or unavailable-asset store.
public struct MigrationResult: Sendable, Equatable {
    /// Number of entries re-keyed to a stable cloud identifier.
    public var cloudMigrated: Int
    /// Number of entries that fell back to the device-local identifier
    /// because PhotoKit reported `.notFound`, `.error`, or no mapping.
    public var localFallback: Int
    /// Old uuids that mapped to the same cloud id during transform. Loser
    /// (older `backedUpAt`) is dropped from the output; both old uuids are
    /// recorded here so the user can inspect.
    public var rekeyCollisions: [String]
    /// Old uuids whose PhotoKit mapping was `.multipleFound` (shared /
    /// merged library). Kept as `.local` until the user manually resolves.
    public var multipleFoundCollisions: [String]
    /// Old uuids whose PhotoKit mapping was `.error(_)`. Kept as `.local`;
    /// runner re-attempts these on the next run.
    public var errors: [String: String]
    /// Old uuids absent from the input mapping entirely (asset deleted from
    /// library since the manifest was written). Kept as-is.
    public var unmapped: [String]

    public init(
        cloudMigrated: Int = 0,
        localFallback: Int = 0,
        rekeyCollisions: [String] = [],
        multipleFoundCollisions: [String] = [],
        errors: [String: String] = [:],
        unmapped: [String] = [],
    ) {
        self.cloudMigrated = cloudMigrated
        self.localFallback = localFallback
        self.rekeyCollisions = rekeyCollisions
        self.multipleFoundCollisions = multipleFoundCollisions
        self.errors = errors
        self.unmapped = unmapped
    }
}

/// Migrate a manifest from v1 (per-device localIdentifier keys) to v2
/// (stable cloud identifier keys where available).
///
/// `mapping` is keyed by the **bare uuid** stored in v1 manifest entries
/// (not the full PhotoKit `"UUID/L0/001"` form). Caller normalizes between
/// the two before invoking this function.
///
/// The function is total and pure: every input combination produces a
/// deterministic v2 manifest plus a `MigrationResult` summarizing what
/// happened. Idempotent: running on an already-v2 manifest returns the
/// input unchanged with all counts zero.
public func migrateManifestToV2(
    _ manifest: Manifest,
    mapping: [String: CloudMappingResult],
) -> (Manifest, MigrationResult) {
    if !manifest.isV1 {
        return (manifest, MigrationResult())
    }

    var result = MigrationResult()
    var newEntries: [String: ManifestEntry] = [:]

    for (oldKey, entry) in manifest.entries {
        switch mapping[oldKey] {
        case .cloud(let cloudId):
            let migrated = ManifestEntry(
                uuid: cloudId,
                s3Key: entry.s3Key,
                checksum: entry.checksum,
                backedUpAt: entry.backedUpAt,
                size: entry.size,
                legacyLocalIdentifier: oldKey,
                identityKind: .cloud,
            )
            if let existing = newEntries[cloudId] {
                // Two old uuids collided onto the same cloud id. Keep the
                // most recently backed-up entry.
                result.rekeyCollisions.append(oldKey)
                if entry.backedUpAt > existing.backedUpAt {
                    newEntries[cloudId] = migrated
                }
            } else {
                newEntries[cloudId] = migrated
                result.cloudMigrated += 1
            }
        case .notFound:
            newEntries[oldKey] = ManifestEntry(
                uuid: oldKey,
                s3Key: entry.s3Key,
                checksum: entry.checksum,
                backedUpAt: entry.backedUpAt,
                size: entry.size,
                legacyLocalIdentifier: oldKey,
                identityKind: .local,
            )
            result.localFallback += 1
        case .multipleFound:
            newEntries[oldKey] = ManifestEntry(
                uuid: oldKey,
                s3Key: entry.s3Key,
                checksum: entry.checksum,
                backedUpAt: entry.backedUpAt,
                size: entry.size,
                legacyLocalIdentifier: oldKey,
                identityKind: .local,
            )
            result.localFallback += 1
            result.multipleFoundCollisions.append(oldKey)
        case .error(let msg):
            newEntries[oldKey] = ManifestEntry(
                uuid: oldKey,
                s3Key: entry.s3Key,
                checksum: entry.checksum,
                backedUpAt: entry.backedUpAt,
                size: entry.size,
                legacyLocalIdentifier: oldKey,
                identityKind: .local,
            )
            result.localFallback += 1
            result.errors[oldKey] = msg
        case .none:
            // Asset present in old manifest but absent from current library.
            // Keep entry untouched; flag for user-visible report.
            newEntries[oldKey] = ManifestEntry(
                uuid: oldKey,
                s3Key: entry.s3Key,
                checksum: entry.checksum,
                backedUpAt: entry.backedUpAt,
                size: entry.size,
                legacyLocalIdentifier: oldKey,
                identityKind: .local,
            )
            result.localFallback += 1
            result.unmapped.append(oldKey)
        }
    }

    let migratedManifest = Manifest(version: currentManifestVersion, entries: newEntries)
    return (migratedManifest, result)
}

/// Migrate a retry queue from v1 uuid keys to v2.
///
/// On collision (two old uuids both mapping to the same cloud id), keeps
/// the entry with the most recent `lastFailedAt`.
public func migrateRetryQueueToV2(
    _ queue: RetryQueue,
    mapping: [String: CloudMappingResult],
) -> (RetryQueue, MigrationResult) {
    var result = MigrationResult()
    var byCanonical: [String: RetryEntry] = [:]

    for entry in queue.entries {
        let canonical: String
        switch mapping[entry.uuid] {
        case .cloud(let cloudId):
            canonical = cloudId
            if let existing = byCanonical[cloudId] {
                result.rekeyCollisions.append(entry.uuid)
                if entry.lastFailedAt > existing.lastFailedAt {
                    byCanonical[cloudId] = RetryEntry(
                        uuid: cloudId,
                        classification: entry.classification,
                        attempts: entry.attempts,
                        firstFailedAt: entry.firstFailedAt,
                        lastFailedAt: entry.lastFailedAt,
                        lastMessage: entry.lastMessage,
                        legacyLocalIdentifier: entry.uuid,
                    )
                }
                continue
            }
            result.cloudMigrated += 1
        case .notFound:
            canonical = entry.uuid
            result.localFallback += 1
        case .multipleFound:
            canonical = entry.uuid
            result.localFallback += 1
            result.multipleFoundCollisions.append(entry.uuid)
        case .error(let msg):
            canonical = entry.uuid
            result.localFallback += 1
            result.errors[entry.uuid] = msg
        case .none:
            canonical = entry.uuid
            result.localFallback += 1
            result.unmapped.append(entry.uuid)
        }

        byCanonical[canonical] = RetryEntry(
            uuid: canonical,
            classification: entry.classification,
            attempts: entry.attempts,
            firstFailedAt: entry.firstFailedAt,
            lastFailedAt: entry.lastFailedAt,
            lastMessage: entry.lastMessage,
            legacyLocalIdentifier: entry.uuid,
        )
    }

    let migrated = RetryQueue(entries: Array(byCanonical.values), updatedAt: queue.updatedAt)
    return (migrated, result)
}

/// Migrate the unavailable-asset store from v1 uuid keys to v2.
///
/// On collision, keeps the entry with the most recent `lastAttemptedAt`.
public func migrateUnavailableStoreToV2(
    _ store: UnavailableAssets,
    mapping: [String: CloudMappingResult],
) -> (UnavailableAssets, MigrationResult) {
    var result = MigrationResult()
    var newEntries: [String: UnavailableAsset] = [:]

    for (oldKey, entry) in store.entries {
        let canonical: String
        switch mapping[oldKey] {
        case .cloud(let cloudId):
            canonical = cloudId
            if let existing = newEntries[cloudId] {
                result.rekeyCollisions.append(oldKey)
                if entry.lastAttemptedAt > existing.lastAttemptedAt {
                    newEntries[cloudId] = UnavailableAsset(
                        uuid: cloudId,
                        filename: entry.filename,
                        reason: entry.reason,
                        firstFailedAt: entry.firstFailedAt,
                        lastAttemptedAt: entry.lastAttemptedAt,
                        attempts: entry.attempts,
                        legacyLocalIdentifier: oldKey,
                    )
                }
                continue
            }
            result.cloudMigrated += 1
        case .notFound:
            canonical = oldKey
            result.localFallback += 1
        case .multipleFound:
            canonical = oldKey
            result.localFallback += 1
            result.multipleFoundCollisions.append(oldKey)
        case .error(let msg):
            canonical = oldKey
            result.localFallback += 1
            result.errors[oldKey] = msg
        case .none:
            canonical = oldKey
            result.localFallback += 1
            result.unmapped.append(oldKey)
        }

        newEntries[canonical] = UnavailableAsset(
            uuid: canonical,
            filename: entry.filename,
            reason: entry.reason,
            firstFailedAt: entry.firstFailedAt,
            lastAttemptedAt: entry.lastAttemptedAt,
            attempts: entry.attempts,
            legacyLocalIdentifier: oldKey,
        )
    }

    return (UnavailableAssets(entries: newEntries), result)
}
