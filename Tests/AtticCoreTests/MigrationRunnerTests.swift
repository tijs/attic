@testable import AtticCore
import Foundation
import LadderKit
import Testing

private typealias Support = MigrationRunnerTestSupport

@Suite("MigrationRunner — core flow")
struct MigrationRunnerTests {
    @Test func migratesAllMappableEntriesEndToEnd() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: Support.v1ManifestData(entries: [
                ("A", "originals/2024/01/A.heic"),
                ("B", "originals/2024/01/B.heic"),
            ]),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/A.json",
            body: Support.metadataJSON(uuid: "A", s3Key: "originals/2024/01/A.heic"),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/B.json",
            body: Support.metadataJSON(uuid: "B", s3Key: "originals/2024/01/B.heic"),
            contentType: "application/json",
        )

        let resolver = Support.MockResolver([
            "A/L0/001": .cloud("CLOUD-A"),
            "B/L0/001": .cloud("CLOUD-B"),
        ])
        let runner = Support.makeRunner(
            s3: s3,
            resolver: resolver,
            library: [
                (bareUUID: "A", fullLocalIdentifier: "A/L0/001"),
                (bareUUID: "B", fullLocalIdentifier: "B/L0/001"),
            ],
        )

        let report = try await runner.run()

        #expect(report.alreadyMigrated == false)
        #expect(report.cloudMigrated == 2)
        #expect(report.metadataRewritten == 2)
        #expect(report.totalEntries == 2)

        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.version == 2)
        #expect(manifest.entries["CLOUD-A"]?.identityKind == .cloud)
        #expect(manifest.entries["CLOUD-A"]?.legacyLocalIdentifier == "A")
        #expect(manifest.entries["A"] == nil)

        let backupExists = try await s3.headObject(key: manifestV1BackupS3Key) != nil
        #expect(backupExists)

        let stagingExists = try await s3.headObject(key: manifestV2StagingS3Key) != nil
        #expect(!stagingExists)

        let newMetaA = try await s3.getObject(key: "metadata/assets/CLOUD-A.json")
        let parsedA = try JSONDecoder().decode(AssetMetadata.self, from: newMetaA)
        #expect(parsedA.uuid == "CLOUD-A")
        #expect(parsedA.legacyLocalIdentifier == "A")
        #expect(parsedA.identityKind == .cloud)
        let oldMetaExists = try await s3.headObject(key: "metadata/assets/A.json") != nil
        #expect(!oldMetaExists)
    }

    @Test func noOpOnAlreadyV2Manifest() async throws {
        let s3 = MockS3Provider()
        var v2 = Manifest()
        v2.markBackedUp(
            uuid: "CLOUD-X",
            s3Key: "originals/2024/01/x.heic",
            checksum: "sha256:x",
            backedUpAt: "2024-01-01T00:00:00Z",
            identityKind: .cloud,
        )
        try await s3.putObject(
            key: manifestS3Key,
            body: v2.encoded(),
            contentType: "application/json",
        )

        let resolver = Support.MockResolver([:])
        let runner = Support.makeRunner(s3: s3, resolver: resolver, library: [])
        let report = try await runner.run()

        #expect(report.alreadyMigrated)
        #expect(report.cloudMigrated == 0)
        #expect(report.totalEntries == 1)
    }

    @Test func dryRunDoesNotMutateS3() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: Support.v1ManifestData(entries: [("A", "originals/2024/01/A.heic")]),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/A.json",
            body: Support.metadataJSON(uuid: "A", s3Key: "originals/2024/01/A.heic"),
        )

        let resolver = Support.MockResolver(["A/L0/001": .cloud("CLOUD-A")])
        let runner = Support.makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")],
        )

        let report = try await runner.run(dryRun: true)

        #expect(report.cloudMigrated == 1)
        #expect(report.metadataRewritten == 0)

        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.isV1)
        #expect(manifest.entries["A"] != nil)

        let stagingExists = try await s3.headObject(key: manifestV2StagingS3Key) != nil
        let backupExists = try await s3.headObject(key: manifestV1BackupS3Key) != nil
        #expect(!stagingExists)
        #expect(!backupExists)
    }

    @Test func partialMetadataRewriteResumes() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: Support.v1ManifestData(entries: [
                ("A", "originals/2024/01/A.heic"),
                ("B", "originals/2024/01/B.heic"),
            ]),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/CLOUD-A.json",
            body: Support.metadataJSON(uuid: "CLOUD-A", s3Key: "originals/2024/01/A.heic"),
        )
        try await s3.putObject(
            key: "metadata/assets/B.json",
            body: Support.metadataJSON(uuid: "B", s3Key: "originals/2024/01/B.heic"),
        )

        let resolver = Support.MockResolver([
            "A/L0/001": .cloud("CLOUD-A"),
            "B/L0/001": .cloud("CLOUD-B"),
        ])
        let runner = Support.makeRunner(
            s3: s3,
            resolver: resolver,
            library: [
                (bareUUID: "A", fullLocalIdentifier: "A/L0/001"),
                (bareUUID: "B", fullLocalIdentifier: "B/L0/001"),
            ],
        )

        let report = try await runner.run()

        #expect(report.metadataRewritten == 1)
        #expect(report.cloudMigrated == 2)

        let bExists = try await s3.headObject(key: "metadata/assets/CLOUD-B.json") != nil
        #expect(bExists)
    }

    @Test func missingMetadataIsSoftSkipped() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: Support.v1ManifestData(entries: [("A", "originals/2024/01/A.heic")]),
            contentType: "application/json",
        )
        let resolver = Support.MockResolver(["A/L0/001": .cloud("CLOUD-A")])
        let runner = Support.makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")],
        )

        let report = try await runner.run()

        #expect(report.cloudMigrated == 1)
        #expect(report.metadataRewritten == 0)
        #expect(report.metadataMissing == 1)

        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(!manifest.isV1)
    }

    @Test func migratesLocalRetryQueueAndUnavailableStore() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: Support.v1ManifestData(entries: [("A", "originals/2024/01/A.heic")]),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/A.json",
            body: Support.metadataJSON(uuid: "A", s3Key: "originals/2024/01/A.heic"),
        )

        let retryStore = Support.InMemoryRetryStore()
        retryStore.queue = RetryQueue(
            entries: [RetryEntry(
                uuid: "A",
                attempts: 2,
                firstFailedAt: "2024-01-01",
                lastFailedAt: "2024-01-05",
            )],
            updatedAt: "2024-01-05",
        )
        let unavailableStore = Support.InMemoryUnavailableStore()
        unavailableStore.assets.entries["A"] = UnavailableAsset(
            uuid: "A",
            filename: "shared.mov",
            reason: "unreachable",
            firstFailedAt: "2024-01-01",
            lastAttemptedAt: "2024-01-05",
            attempts: 1,
        )

        let resolver = Support.MockResolver(["A/L0/001": .cloud("CLOUD-A")])
        let runner = Support.makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")],
            retryStore: retryStore,
            unavailableStore: unavailableStore,
        )

        _ = try await runner.run()

        #expect(retryStore.queue?.entries.first?.uuid == "CLOUD-A")
        #expect(retryStore.queue?.entries.first?.legacyLocalIdentifier == "A")
        #expect(unavailableStore.assets.entries["CLOUD-A"]?.legacyLocalIdentifier == "A")
        #expect(unavailableStore.assets.entries["A"] == nil)
    }

    @Test func unmappedAssetsRemainAsLocal() async throws {
        let s3 = MockS3Provider()
        try await s3.putObject(
            key: manifestS3Key,
            body: Support.v1ManifestData(entries: [
                ("A", "originals/2024/01/A.heic"),
                ("DELETED", "originals/2024/01/DELETED.heic"),
            ]),
            contentType: "application/json",
        )
        try await s3.putObject(
            key: "metadata/assets/A.json",
            body: Support.metadataJSON(uuid: "A", s3Key: "originals/2024/01/A.heic"),
        )

        let resolver = Support.MockResolver(["A/L0/001": .cloud("CLOUD-A")])
        let runner = Support.makeRunner(
            s3: s3,
            resolver: resolver,
            library: [(bareUUID: "A", fullLocalIdentifier: "A/L0/001")],
        )

        let report = try await runner.run()

        #expect(report.cloudMigrated == 1)
        #expect(report.unmapped == ["DELETED"])
        let manifest = try await S3ManifestStore(s3: s3).load()
        #expect(manifest.entries["DELETED"]?.identityKind == .local)
    }
}
