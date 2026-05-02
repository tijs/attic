@testable import AtticCore
import Foundation
import LadderKit
import Testing

@Suite("CloudIdentityMigration — manifest")
struct ManifestMigrationTests {
    private func entry(uuid: String, backedUpAt: String) -> ManifestEntry {
        ManifestEntry(
            uuid: uuid,
            s3Key: "originals/2024/01/\(uuid).heic",
            checksum: "sha256:\(uuid)",
            backedUpAt: backedUpAt,
            identityKind: .local,
        )
    }

    private func v1Manifest(_ entries: [ManifestEntry]) -> Manifest {
        var dict: [String: ManifestEntry] = [:]
        for e in entries { dict[e.uuid] = e }
        return Manifest(version: 1, entries: dict)
    }

    @Test func migratesAllMappableEntries() {
        let manifest = v1Manifest([
            entry(uuid: "A", backedUpAt: "2024-01-01"),
            entry(uuid: "B", backedUpAt: "2024-01-02"),
            entry(uuid: "C", backedUpAt: "2024-01-03"),
        ])
        let mapping: [String: CloudMappingResult] = [
            "A": .cloud("CLOUD-A"),
            "B": .cloud("CLOUD-B"),
            "C": .cloud("CLOUD-C"),
        ]
        let (migrated, report) = migrateManifestToV2(manifest, mapping: mapping)

        #expect(migrated.version == 2)
        #expect(migrated.entries.count == 3)
        #expect(report.cloudMigrated == 3)
        #expect(report.localFallback == 0)
        #expect(report.rekeyCollisions.isEmpty)

        let migA = try? #require(migrated.entries["CLOUD-A"])
        #expect(migA?.identityKind == .cloud)
        #expect(migA?.legacyLocalIdentifier == "A")
        #expect(migA?.s3Key == "originals/2024/01/A.heic")
    }

    @Test func notFoundAssetsKeepLocalFallback() {
        let manifest = v1Manifest([
            entry(uuid: "A", backedUpAt: "2024-01-01"),
            entry(uuid: "B", backedUpAt: "2024-01-02"),
        ])
        let mapping: [String: CloudMappingResult] = [
            "A": .cloud("CLOUD-A"),
            "B": .notFound,
        ]
        let (migrated, report) = migrateManifestToV2(manifest, mapping: mapping)

        #expect(migrated.entries.count == 2)
        #expect(report.cloudMigrated == 1)
        #expect(report.localFallback == 1)
        #expect(migrated.entries["CLOUD-A"]?.identityKind == .cloud)
        #expect(migrated.entries["B"]?.identityKind == .local)
        #expect(migrated.entries["B"]?.legacyLocalIdentifier == "B")
    }

    @Test func absentFromMappingFlaggedAsUnmapped() {
        let manifest = v1Manifest([
            entry(uuid: "A", backedUpAt: "2024-01-01"),
            entry(uuid: "B", backedUpAt: "2024-01-02"),
        ])
        let mapping: [String: CloudMappingResult] = ["A": .cloud("CLOUD-A")]
        let (migrated, report) = migrateManifestToV2(manifest, mapping: mapping)

        #expect(migrated.entries.count == 2)
        #expect(report.cloudMigrated == 1)
        #expect(report.localFallback == 1)
        #expect(report.unmapped == ["B"])
        #expect(migrated.entries["B"]?.identityKind == .local)
    }

    @Test func multipleFoundFlaggedNotSilentlyResolved() {
        let manifest = v1Manifest([
            entry(uuid: "A", backedUpAt: "2024-01-01"),
        ])
        let mapping: [String: CloudMappingResult] = ["A": .multipleFound]
        let (migrated, report) = migrateManifestToV2(manifest, mapping: mapping)

        #expect(report.multipleFoundCollisions == ["A"])
        #expect(report.localFallback == 1)
        #expect(migrated.entries["A"]?.identityKind == .local)
    }

    @Test func errorFlaggedForRetryNextRun() {
        let manifest = v1Manifest([
            entry(uuid: "A", backedUpAt: "2024-01-01"),
        ])
        let mapping: [String: CloudMappingResult] = ["A": .error("transient PhotoKit failure")]
        let (migrated, report) = migrateManifestToV2(manifest, mapping: mapping)

        #expect(report.errors["A"] == "transient PhotoKit failure")
        #expect(report.localFallback == 1)
        #expect(migrated.entries["A"]?.identityKind == .local)
    }

    @Test func rekeyCollisionKeepsMostRecent() {
        let manifest = v1Manifest([
            entry(uuid: "A", backedUpAt: "2024-01-01T00:00:00Z"),
            entry(uuid: "B", backedUpAt: "2024-06-01T00:00:00Z"),
        ])
        let mapping: [String: CloudMappingResult] = [
            "A": .cloud("CLOUD-X"),
            "B": .cloud("CLOUD-X"),
        ]
        let (migrated, report) = migrateManifestToV2(manifest, mapping: mapping)

        #expect(migrated.entries.count == 1)
        #expect(report.rekeyCollisions.count == 1)
        let winner = try? #require(migrated.entries["CLOUD-X"])
        #expect(winner?.s3Key == "originals/2024/01/B.heic")
        #expect(winner?.backedUpAt == "2024-06-01T00:00:00Z")
    }

    @Test func emptyManifestProducesEmptyV2() {
        let manifest = Manifest(version: 1, entries: [:])
        let (migrated, report) = migrateManifestToV2(manifest, mapping: [:])
        #expect(migrated.version == 2)
        #expect(migrated.entries.isEmpty)
        #expect(report.cloudMigrated == 0)
        #expect(report.localFallback == 0)
    }

    @Test func idempotentOnV2Manifest() {
        var v2 = Manifest()
        v2.markBackedUp(
            uuid: "CLOUD-A",
            s3Key: "originals/2024/01/legacy.heic",
            checksum: "sha256:c",
            backedUpAt: "2024-01-01T00:00:00Z",
            legacyLocalIdentifier: "legacy",
            identityKind: .cloud,
        )
        let mapping: [String: CloudMappingResult] = ["CLOUD-A": .cloud("SOMETHING-ELSE")]
        let (migrated, report) = migrateManifestToV2(v2, mapping: mapping)

        #expect(migrated.entries["CLOUD-A"] != nil)
        #expect(report.cloudMigrated == 0)
        #expect(report.localFallback == 0)
    }
}

@Suite("CloudIdentityMigration — retry queue + unavailable store")
struct QueueMigrationTests {
    @Test func retryQueueRekeysAndPreservesAttempts() {
        let queue = RetryQueue(
            entries: [
                RetryEntry(
                    uuid: "A",
                    classification: .transientCloud,
                    attempts: 3,
                    firstFailedAt: "2024-01-01",
                    lastFailedAt: "2024-01-02",
                    lastMessage: "timeout",
                ),
            ],
            updatedAt: "2024-01-02",
        )
        let mapping: [String: CloudMappingResult] = ["A": .cloud("CLOUD-A")]
        let (migrated, report) = migrateRetryQueueToV2(queue, mapping: mapping)

        #expect(migrated.entries.count == 1)
        #expect(migrated.entries[0].uuid == "CLOUD-A")
        #expect(migrated.entries[0].attempts == 3)
        #expect(migrated.entries[0].lastMessage == "timeout")
        #expect(migrated.entries[0].legacyLocalIdentifier == "A")
        #expect(report.cloudMigrated == 1)
    }

    @Test func unavailableStoreRekeysAndPreservesFirstSeen() {
        var store = UnavailableAssets()
        store.entries["A"] = UnavailableAsset(
            uuid: "A",
            filename: "shared.mov",
            reason: "shared-album-derivative-unreachable",
            firstFailedAt: "2024-01-01",
            lastAttemptedAt: "2024-01-05",
            attempts: 2,
        )
        let mapping: [String: CloudMappingResult] = ["A": .cloud("CLOUD-A")]
        let (migrated, report) = migrateUnavailableStoreToV2(store, mapping: mapping)

        #expect(migrated.entries["CLOUD-A"]?.firstFailedAt == "2024-01-01")
        #expect(migrated.entries["CLOUD-A"]?.attempts == 2)
        #expect(migrated.entries["CLOUD-A"]?.reason == "shared-album-derivative-unreachable")
        #expect(migrated.entries["CLOUD-A"]?.legacyLocalIdentifier == "A")
        #expect(report.cloudMigrated == 1)
    }

    @Test func retryQueueCollisionKeepsMostRecentLastFailedAt() {
        let queue = RetryQueue(
            entries: [
                RetryEntry(
                    uuid: "A",
                    classification: .other,
                    attempts: 1,
                    firstFailedAt: "2024-01-01",
                    lastFailedAt: "2024-01-01T00:00:00Z",
                ),
                RetryEntry(
                    uuid: "B",
                    classification: .other,
                    attempts: 1,
                    firstFailedAt: "2024-06-01",
                    lastFailedAt: "2024-06-01T00:00:00Z",
                ),
            ],
            updatedAt: "now",
        )
        let mapping: [String: CloudMappingResult] = [
            "A": .cloud("CLOUD-X"),
            "B": .cloud("CLOUD-X"),
        ]
        let (migrated, report) = migrateRetryQueueToV2(queue, mapping: mapping)

        #expect(migrated.entries.count == 1)
        #expect(report.rekeyCollisions.count == 1)
        #expect(migrated.entries[0].lastFailedAt == "2024-06-01T00:00:00Z")
    }
}
